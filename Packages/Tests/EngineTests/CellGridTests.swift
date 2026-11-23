@testable import Engine
import Testing

@Test func cellGridVisitsNeighborCellsInLoopOrder() {
    var rng = SystemRandomNumberGenerator()
    let cell: Float = 0.7
    let points = (0..<500).map { _ in
        SIMD3(Float.random(in: -5...5, using: &rng), Float.random(in: -5...5, using: &rng), Float.random(in: -5...5, using: &rng))
    }
    let grid = CellGrid(points, cell: cell)
    for _ in 0..<200 {
        let x = SIMD3(Float.random(in: -6...6, using: &rng), Float.random(in: -6...6, using: &rng), Float.random(in: -6...6, using: &rng))
        let c = CellGrid.coord(x, cell)
        // 前の辞書の実装と同じ順: dx・dy・dz の順にセルを回り、同じセルの中は番号順
        var want: [Int] = []
        for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
            want += points.indices.filter { CellGrid.coord(points[$0], cell) == c &+ SIMD3(dx, dy, dz) }
        } } }
        var got: [Int] = []
        grid.near(x) { got.append($0) }
        #expect(got == want)
    }
}
