import SwiftUI

struct AppLogo: View {
    let size: CGFloat
    
    var body: some View {
        Image("AppLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .cornerRadius(size * 0.2237) // Matches iOS icon curvature
            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}
