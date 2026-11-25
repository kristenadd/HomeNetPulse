import SwiftUI

/// A non-lazy grid: as many equal-width columns as fit (each at least `minColumnWidth`),
/// rows as tall as their tallest item. Unlike LazyVGrid inside a ScrollView, every item is
/// measured up front, so cards keep a stable height while scrolling.
struct EqualColumns: Layout {
    var minColumnWidth: CGFloat
    var hSpacing: CGFloat = 12
    var vSpacing: CGFloat = 10

    private func columnCount(for width: CGFloat) -> Int {
        max(1, Int((width + hSpacing) / (minColumnWidth + hSpacing)))
    }

    private func metrics(width: CGFloat, subviews: Subviews) -> (cols: Int, colWidth: CGFloat, rowHeights: [CGFloat]) {
        let cols = columnCount(for: width)
        let colWidth = max(0, (width - hSpacing * CGFloat(cols - 1)) / CGFloat(cols))
        var rowHeights: [CGFloat] = []
        var i = 0
        while i < subviews.count {
            let row = subviews[i ..< min(i + cols, subviews.count)]
            rowHeights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height }.max() ?? 0)
            i += cols
        }
        return (cols, colWidth, rowHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        var width = proposal.width ?? minColumnWidth * 2 + hSpacing
        if !width.isFinite { width = minColumnWidth * CGFloat(subviews.count) + hSpacing * CGFloat(subviews.count - 1) }
        let m = metrics(width: width, subviews: subviews)
        let height = m.rowHeights.reduce(0, +) + vSpacing * CGFloat(max(0, m.rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (r, rowHeight) in m.rowHeights.enumerated() {
            for c in 0 ..< m.cols {
                let index = r * m.cols + c
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(c) * (m.colWidth + hSpacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: m.colWidth, height: rowHeight))
            }
            y += rowHeight + vSpacing
        }
    }
}
