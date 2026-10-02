// Standalone driver for the EECBS low-level search kernel.
//
// Calls the unmodified SpaceTimeAStar::findSuboptimalPath() (which bundles insert2CT +
// insert2CAT + the focal A* loop) many times, the way ECBS::findPathForSingleAgent does,
// but without running the high-level CBS search. Two ways to get the calls:
//
//   replay (--trace F)  : replay low-level calls recorded from a real eecbs run (built with
//                         -DKERNEL_TRACE, filtered by select_trace.py). Inputs are the real ones:
//                         agent, lowerbound, w, constraint chain, all other agents' paths.
//   synthetic (default) : plan every agent once, then replan agents against hand-made blocking
//                         constraints (--constraints/--block-len). Used for controlled sweeps.
//
// Phases: setup (not measured) -> warmup (--warmup calls, not measured) -> ROI (--iters calls,
// bracketed by m5_reset_stats()/m5_dump_stats() when built with -DUSE_M5OPS).
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <functional>
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
	string map, scen, trace, per_call;
	int agents = 50;
	int iters = 200;
	int warmup = 0;
	int constraints = 3;  // synthetic: chain depth, i.e. number of blocking events per replan
	int block_len = 4;    // synthetic: each event blocks one cell for this many consecutive timesteps
	double w = 1.2;       // synthetic: suboptimality bound (replay uses the recorded w)
	unsigned seed = 1;
};

static void usage(const char* prog)
{
	fprintf(stderr,
	        "usage: %s --map F --scen F [--trace F] [--per-call F] [--agents K] [--iters N] [--warmup N]\n"
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
		else if (is("--trace")) a.trace = argv[++i];
		else if (is("--per-call")) a.per_call = argv[++i];
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
	uint64_t calls = 0, expanded = 0, generated = 0, path_len = 0, empty = 0;
	uint64_t recorded_expanded = 0;  // replay only: expansions the real run spent on the same calls
	uint64_t checksum = 0;           // folds in every returned path so runs can be compared bit-for-bit
	// replay only: comparison with what the real run got back for the same call
	uint64_t compared = 0, status_mismatch = 0, size_mismatch = 0, path_mismatch = 0;
	uint64_t found_calls = 0, notfound_calls = 0, exp_diff_found = 0, exp_diff_notfound = 0;
	double max_exp_dev = 0;  // largest |replay - recorded| / recorded expansions over all calls
};

// ---------------------------------------------------------------------------------------------
// trace replay
// ---------------------------------------------------------------------------------------------
struct TraceCall
{
	int agent = 0, lowerbound = 0;
	double w = 1;
	uint64_t expanded = 0, generated = 0;
	vector<list<Constraint>> nodes;  // constraint list of each HL node, deepest first
	vector<Path> paths;              // every agent's path (empty = none / the replanned agent itself)
	bool has_result = false;         // trace v1 files written before RESULT existed do not have it
	size_t result_size = 0;          // path the real run got back (0 = no path)
	uint64_t result_checksum = 0;
};

static void bad_trace(const char* what)
{
	fprintf(stderr, "malformed trace: %s\n", what);
	exit(1);
}

static vector<TraceCall> loadTrace(const string& fname, int& num_agents)
{
	std::ifstream in(fname);
	if (!in.is_open()) bad_trace("cannot open file");
	string tok;
	int rows, cols;
	if (!(in >> tok) || tok != "TRACE") bad_trace("missing TRACE header");
	in >> tok;  // version
	if (!(in >> tok) || tok != "INSTANCE") bad_trace("missing INSTANCE line");
	in >> num_agents >> rows >> cols;

	vector<TraceCall> calls;
	while (in >> tok)
	{
		if (tok != "CALL") bad_trace("expected CALL");
		TraceCall c;
		long id;
		in >> id >> c.agent >> c.lowerbound >> c.w >> c.expanded >> c.generated;

		size_t num_nodes;
		in >> tok >> num_nodes;  // NODES n
		if (tok != "NODES") bad_trace("expected NODES");
		c.nodes.resize(num_nodes);
		for (size_t i = 0; i < num_nodes; i++)
		{
			size_t m;
			in >> tok >> m;  // N m a x y t type ...
			if (tok != "N") bad_trace("expected N");
			for (size_t j = 0; j < m; j++)
			{
				int a, x, y, t, type;
				in >> a >> x >> y >> t >> type;
				c.nodes[i].emplace_back(a, x, y, t, (constraint_type)type);
			}
		}

		in >> tok;
		if (tok != "PATHS") bad_trace("expected PATHS");
		c.paths.resize(num_agents);
		for (int i = 0; i < num_agents; i++)
		{
			size_t len;
			in >> len;
			c.paths[i].resize(len);
			for (size_t j = 0; j < len; j++)
				in >> c.paths[i][j].location;
		}
		in >> tok;
		if (tok == "RESULT")
		{
			in >> c.result_size >> c.result_checksum;
			c.has_result = true;
			in >> tok;
		}
		if (tok != "END" || !in) bad_trace("expected END");
		calls.push_back(std::move(c));
	}
	return calls;
}

// A replayable call: HL node chain and path-pointer vector are built once in setup so that the
// ROI contains little besides findSuboptimalPath itself.
struct PreparedCall
{
	vector<std::unique_ptr<CBSNode>> chain;
	HLNode* top = nullptr;
	vector<Path*> paths;
};

int main(int argc, char** argv)
{
	Args args = parse(argc, argv);
	srand(args.seed);  // only the LLNode tie-break (rand() % 2) consumes this stream
	std::mt19937 rng(args.seed * 2654435761u + 1);  // separate stream for synthetic input construction

	vector<TraceCall> trace;
	int K = args.agents;
	if (!args.trace.empty())
	{
		trace = loadTrace(args.trace, K);
		if (trace.empty()) bad_trace("no calls");
	}

	Instance instance(args.map, args.scen, K);
	if (args.trace.empty())
	{
		K = instance.getDefaultNumberOfAgents();
		if (args.agents > 0 && args.agents < K) K = args.agents;
	}
	else if (instance.getDefaultNumberOfAgents() < K)
	{
		fprintf(stderr, "trace has %d agents but the scenario file only %d\n", K, instance.getDefaultNumberOfAgents());
		return 1;
	}

	vector<std::unique_ptr<SpaceTimeAStar>> engines(K);  // created lazily: each costs one BFS over the map
	auto engine = [&](int i) -> SpaceTimeAStar&
	{
		if (!engines[i]) engines[i].reset(new SpaceTimeAStar(instance, i));
		return *engines[i];
	};
	vector<ConstraintTable> init_ct(K, ConstraintTable(instance.num_of_cols, instance.map_size));
	CBSNode root;  // HLNode with parent == nullptr => carries no constraints

	Totals tot;
	std::function<void(int, Totals&)> replan;
	FILE* per_call = nullptr;  // replay: one line per measured call (index found recorded_expanded replay_expanded)
	if (!args.per_call.empty()) per_call = fopen(args.per_call.c_str(), "w");

	// bookkeeping shared by both modes
	auto account = [](Totals& t, const SpaceTimeAStar& e, const pair<Path, int>& res)
	{
		t.calls++;
		t.expanded += e.num_expanded;
		t.generated += e.num_generated;
		if (res.first.empty())
		{
			t.empty++;
			return;
		}
		t.path_len += res.first.size();
		for (auto& p : res.first)
			t.checksum = t.checksum * 1000003u + (uint64_t)p.location + 1;
	};

	vector<PreparedCall> prepared;
	vector<pair<Path, int>> initial;
	vector<Path*> paths;

	if (!args.trace.empty())
	{
		// ---- replay setup
		prepared.resize(trace.size());
		for (size_t c = 0; c < trace.size(); c++)
		{
			PreparedCall& pc = prepared[c];
			HLNode* parent = &root;
			for (size_t i = trace[c].nodes.size(); i-- > 0;)  // shallowest first so parents exist
			{
				std::unique_ptr<CBSNode> n(new CBSNode());
				n->HLNode::parent = parent;
				n->constraints = trace[c].nodes[i];
				parent = n.get();
				pc.chain.push_back(std::move(n));
			}
			pc.top = parent;
			pc.paths.resize(K, nullptr);
			for (int i = 0; i < K; i++)
				if (!trace[c].paths[i].empty())
					pc.paths[i] = &trace[c].paths[i];
			engine(trace[c].agent);  // build the BFS heuristic now, outside the ROI
		}
		replan = [&](int it, Totals& t)
		{
			size_t c = (size_t)it % trace.size();
			const TraceCall& tc = trace[c];
			SpaceTimeAStar& e = engine(tc.agent);
			auto res = e.findSuboptimalPath(*prepared[c].top, init_ct[tc.agent], prepared[c].paths,
			                                tc.agent, tc.lowerbound, tc.w);
			t.recorded_expanded += tc.expanded;
			if (per_call && &t == &tot)
				fprintf(per_call, "%zu %d %llu %llu\n", c, res.first.empty() ? 0 : 1,
				        (unsigned long long)tc.expanded, (unsigned long long)e.num_expanded);
			{
				bool found = !res.first.empty();
				(found ? t.found_calls : t.notfound_calls)++;
				if (e.num_expanded != tc.expanded)
					(found ? t.exp_diff_found : t.exp_diff_notfound)++;
				double dev = std::fabs((double)e.num_expanded - (double)tc.expanded) / std::max(1.0, (double)tc.expanded);
				if (dev > t.max_exp_dev) t.max_exp_dev = dev;
			}
			if (tc.has_result)
			{
				uint64_t cs = 0;
				for (auto& p : res.first)
					cs = cs * 1000003u + (uint64_t)p.location + 1;
				t.compared++;
				if ((res.first.empty()) != (tc.result_size == 0)) t.status_mismatch++;  // found vs not found
				if (res.first.size() != tc.result_size) t.size_mismatch++;
				if (res.first.size() != tc.result_size || cs != tc.result_checksum) t.path_mismatch++;
			}
			account(t, e, res);
		};
		fprintf(stderr, "setup done: replaying %zu recorded calls, %d agents, %dx%d map\n", trace.size(), K,
		        instance.num_of_rows, instance.num_of_cols);
	}
	else
	{
		// ---- synthetic setup: plan every agent once (these paths become the CAT of later calls)
		paths.assign(K, nullptr);
		initial.resize(K);
		for (int i = 0; i < K; i++)
		{
			initial[i] = engine(i).findSuboptimalPath(root, init_ct[i], paths, i, 0, args.w);
			if (initial[i].first.empty())
			{
				fprintf(stderr, "agent %d: start and goal are not connected\n", i);
				return 1;
			}
			paths[i] = &initial[i].first;
		}
		fprintf(stderr, "setup done: %d agents on %dx%d map\n", K, instance.num_of_rows, instance.num_of_cols);

		replan = [&](int it, Totals& t)
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
			auto res = engine(a).findSuboptimalPath(*prev, init_ct[a], paths, a, initial[a].second, args.w);
			account(t, engine(a), res);
		};
	}

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

	if (per_call) fclose(per_call);
	double secs = std::chrono::duration<double>(t1 - t0).count();
	printf("calls=%llu expanded=%llu generated=%llu path_len_sum=%llu empty=%llu checksum=%llu wall=%.3fs",
	       (unsigned long long)tot.calls, (unsigned long long)tot.expanded, (unsigned long long)tot.generated,
	       (unsigned long long)tot.path_len, (unsigned long long)tot.empty, (unsigned long long)tot.checksum, secs);
	if (!args.trace.empty())
		printf(" recorded_expanded=%llu replay/recorded=%.3f", (unsigned long long)tot.recorded_expanded,
		       tot.recorded_expanded ? (double)tot.expanded / (double)tot.recorded_expanded : 0.0);
	if (!args.trace.empty() && tot.compared > 0)
		printf(" | vs real run over %llu calls: found/not-found differs %llu, path length differs %llu, path differs %llu",
		       (unsigned long long)tot.compared, (unsigned long long)tot.status_mismatch,
		       (unsigned long long)tot.size_mismatch, (unsigned long long)tot.path_mismatch);
	if (!args.trace.empty() && tot.compared > 0)
		printf(" | per-call expansions: not-found calls %llu (differ %llu), found calls %llu (differ %llu), max deviation %.2f%%",
		       (unsigned long long)tot.notfound_calls, (unsigned long long)tot.exp_diff_notfound,
		       (unsigned long long)tot.found_calls, (unsigned long long)tot.exp_diff_found, 100.0 * tot.max_exp_dev);
	printf("\n");
	return 0;
}
