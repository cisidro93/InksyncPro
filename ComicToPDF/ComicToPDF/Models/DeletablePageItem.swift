import SwiftUI

struct DeletablePageItem: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let thumbnail: UIImage
    var isSelected: Bool
}
