function prioritize(c) {
    let old = json(sprintf("%J", c));
    let group = null;
    for (let o in c.outbounds) {
        if (o.tag != "T") continue;
        if (group != null || o.type != "fallback" ||
            sprintf("%J", o.outbounds) != sprintf("%J", ["TR-2", "TR-1", "TR-3"]))
            die("unexpected T baseline");
        group = o;
    }
    if (group == null) die("T missing");
    group.outbounds = ["TR-1", "TR-2", "TR-3"];
    let changed = json(sprintf("%J", c));
    group.outbounds = ["TR-2", "TR-1", "TR-3"];
    if (sprintf("%J", c) != sprintf("%J", old)) die("unrelated difference");
    return changed;
}
