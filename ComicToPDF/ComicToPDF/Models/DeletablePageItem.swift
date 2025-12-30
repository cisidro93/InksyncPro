import SwiftUI
import UIKit

struct DeletablePageItem: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let thumbnail: UIImage
    var isSelected: Bool
}
