// Standalone driver for the EECBS low-level search kernel.
//
// Calls the unmodified SpaceTimeAStar::findSuboptimalPath() (which bundles insert2CT +
// insert2CAT + the focal A* loop) many times, the way ECBS::findPathForSingleAgent does,
// but without running the high-level CBS search. Inputs (map, agents, constraint pattern)
// are small and fully controlled by command-line flags, so the run is deterministic and
// cheap enough for gem5.
//
// Phases:
//   setup   : load instance, build one SpaceTimeAStar per agent (BFS heuristics), plan all
//             agents once (these paths become the conflict-avoidance table of later calls)
//   warmup  : --warmup replans, not measured (warms caches / branch predictor)
//   ROI     : --iters replans, bracketed by m5_reset_stats()/m5_dump_stats() when built
//             with -DUSE_M5OPS
//
// One replan = pick agent a (round robin), build a chain of --constraints HLNodes, each
// blocking one cell of a's own initial path for --block-len consecutive timesteps, then call
// findSuboptimalPath(chain, ..., lowerbound = min_f of a's initial path, w).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <chrono>
#include "SpaceTimeAStar.h"

#ifdef USE_M5OPS
#include <gem5/m5ops.h>
#endif

struct Args
{
	string map, scen;
	int agents = 50;
	int iters = 200;
	int warmup = 0;
	int constraints = 3;  // chain depth: number of blocking events per replan
	int block_len = 4;    // each event blocks one cell for this many consecutive timesteps
	double w = 1.2;       // suboptimality bound, same meaning as EECBS --suboptimality
	unsigned seed = 1;
};

static void usage(const char* prog)
{
	fprintf(stderr,
	        "usage: %s --map F --scen F [--agents K] [--iters N] [--warmup N]\n"
	        "          [--constraints C] [--block-len B] [--w W] [--seed S]\n", prog);
	exit(1);
}

static Args parse(int argc, char** argv)
{
	Args a;
	for (int i = 1; i < argc; i++)
	{
		auto is = [&](const char* name) { return strcmp(argv[i], name) == 0; };
		if (i + 1 >= argc) usage(argv[0]);
		if (is("--map")) a.map = argv[++i];
		else if (is("--scen")) a.scen = argv[++i];
		else if (is("--agents")) a.agents = atoi(argv[++i]);
		else if (is("--iters")) a.iters = atoi(argv[++i]);
		else if (is("--warmup")) a.warmup = atoi(argv[++i]);
		else if (is("--constraints")) a.constraints = atoi(argv[++i]);
		else if (is("--block-len")) a.block_len = atoi(argv[++i]);
		else if (is("--w")) a.w = atof(argv[++i]);
		else if (is("--seed")) a.seed = (unsigned)atoi(argv[++i]);
		else usage(argv[0]);
	}
	if (a.map.empty() || a.scen.empty()) usage(argv[0]);
	return a;
}

struct Totals
{
	uint64_t expanded = 0, generated = 0, path_len = 0, empty = 0;
	uint64_t checksum = 0;  // folds in every returned path so runs can be compared bit-for-bit
};

int main(int argc, char** argv)
{
	Args args = parse(argc, argv);
	srand(args.seed);  // only the LLNode tie-break (rand() % 2) consumes this stream
	std::mt19937 rng(args.seed * 2654435761u + 1);  // separate stream for input construction

	Instance instance(args.map, args.scen, args.agents);
	int K = instance.getDefaultNumberOfAgents();
	if (args.agents > 0 && args.agents < K) K = args.agents;

	vector<std::unique_ptr<SpaceTimeAStar>> engines;
	vector<ConstraintTable> init_ct(K, ConstraintTable(instance.num_of_cols, instance.map_size));
	for (int i = 0; i < K; i++)
		engines.emplace_back(new SpaceTimeAStar(instance, i));

	// ---- setup: plan every agent once (root node has parent == nullptr => no constraints)
	CBSNode root;
	vector<Path*> paths(K, nullptr);
	vector<pair<Path, int>> initial(K);
	for (int i = 0; i < K; i++)
	{
		initial[i] = engines[i]->findSuboptimalPath(root, init_ct[i], paths, i, 0, args.w);
		if (initial[i].first.empty())
		{
			fprintf(stderr, "agent %d: start and goal are not connected\n", i);
			return 1;
		}
		paths[i] = &initial[i].first;
	}
	fprintf(stderr, "setup done: %d agents on %dx%d map\n", K, instance.num_of_rows, instance.num_of_cols);

	// ---- one replan
	Totals tot;
	auto replan = [&](int it, Totals& t)
	{
		int a = it % K;
		const Path& P = initial[a].first;
		int len = (int)P.size();
		if (len < 3) return;  // nothing to block between start and goal

		// chain: root <- n0 <- n1 ... ; every node blocks one cell of P for block_len steps
		vector<std::unique_ptr<CBSNode>> chain;
		HLNode* prev = &root;
		for (int c = 0; c < args.constraints; c++)
		{
			int ts = 1 + (int)(rng() % (unsigned)(len - 1));  // 1 .. len-1, never the start at t=0
			std::unique_ptr<CBSNode> n(new CBSNode());
			n->HLNode::parent = prev;
			for (int d = 0; d < args.block_len; d++)
				n->constraints.emplace_back(a, P[ts].location, -1, ts + d, constraint_type::VERTEX);
			prev = n.get();
			chain.push_back(std::move(n));
		}

		auto res = engines[a]->findSuboptimalPath(*prev, init_ct[a], paths, a, initial[a].second, args.w);
		t.expanded += engines[a]->num_expanded;
		t.generated += engines[a]->num_generated;
		if (res.first.empty())
		{
			t.empty++;
			return;
		}
		t.path_len += res.first.size();
		for (auto& e : res.first)
			t.checksum = t.checksum * 1000003u + (uint64_t)e.location + 1;
	};

	for (int it = 0; it < args.warmup; it++)
	{
		Totals scratch;
		replan(it, scratch);
	}

#ifdef USE_M5OPS
	m5_reset_stats(0, 0);
#endif
	auto t0 = std::chrono::steady_clock::now();
	for (int it = 0; it < args.iters; it++)
		replan(args.warmup + it, tot);
	auto t1 = std::chrono::steady_clock::now();
#ifdef USE_M5OPS
	m5_dump_stats(0, 0);
#endif

	double secs = std::chrono::duration<double>(t1 - t0).count();
	printf("iters=%d expanded=%llu generated=%llu path_len_sum=%llu empty=%llu checksum=%llu wall=%.3fs\n",
	       args.iters, (unsigned long long)tot.expanded, (unsigned long long)tot.generated,
	       (unsigned long long)tot.path_len, (unsigned long long)tot.empty,
	       (unsigned long long)tot.checksum, secs);
	return 0;
}
