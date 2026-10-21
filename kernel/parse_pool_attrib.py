#!/usr/bin/env python3
import sys
want = sys.argv[2] if len(sys.argv)>2 else "system.l2"
names=["AStarNode","HashTable","OpenHeap","FocalHeap","ConstraintTable","CAT"]
for line in open(sys.argv[1]):
    if not line.startswith("CACHE "): continue
    toks=line.split(); cache=toks[1]
    if want!=cache: continue
    kv=dict(t.split("=") for t in toks[2:] if "=" in t)
    per=[int(kv.get(n,0)) for n in names]
    attr=sum(per); other=int(kv.get("other",0)); no_va=int(kv.get("noVaddr",0))
    print("cache %s: attributed=%d other=%d noVaddr=%d"%(cache,attr,other,no_va))
    print("  vaddr-attributed share of demand (attr+other): %.1f%%"%(100*attr/max(attr+other,1)))
    for n,c in sorted(zip(names,per),key=lambda x:-x[1]):
        print("    %-16s %8d  %5.1f%%"%(n,c,100*c/max(attr,1)))
