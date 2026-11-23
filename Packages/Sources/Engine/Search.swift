extension Array {
    /// `pred` が前は真・後ろは偽に並んでいるとき、最初に偽になる位置。
    func partitionPoint(_ pred: (Element) -> Bool) -> Int {
        var (lo, hi) = (0, count)
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(self[mid]) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

extension Sequence {
    /// 同じ値ならあとのもの。
    func lastMax(by less: (Element, Element) -> Bool) -> Element? {
        var best: Element?
        for x in self where best.map({ !less(x, $0) }) ?? true { best = x }
        return best
    }

    /// 同じ値ならあとのもの。
    func lastMax<K: Comparable>(_ key: (Element) -> K) -> Element? {
        lastMax { key($0) < key($1) }
    }
}
