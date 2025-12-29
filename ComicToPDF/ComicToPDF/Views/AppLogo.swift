import SwiftUI

// MARK: - App Logo View
// Use this anywhere in your app to display the logo

struct AppLogo: View {
    var size: CGFloat = 120
    
    var body: some View {
        ZStack {
            // Background rounded rectangle with gradient
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 253/255, green: 186/255, blue: 116/255), // #FDBA74
                            Color(red: 249/255, green: 115/255, blue: 22/255),  // #F97316
                            Color(red: 194/255, green: 65/255, blue: 12/255)    // #C2410C
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            
            // Content
            VStack(alignment: .leading, spacing: size * 0.02) {
                // CBZ text
                Text("CBZ")
                    .font(.system(size: size * 0.15, weight: .heavy, design: .default))
                    .foregroundColor(.white.opacity(0.95))
                
                // Divider line with arrow
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(height: 2)
                    
                    // Arrow
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: size * 0.1))
                        .foregroundColor(.white.opacity(0.9))
                }
                .frame(width: size * 0.65)
                
                // PDF text
                Text("PDF")
                    .font(.system(size: size * 0.2, weight: .heavy, design: .default))
                    .foregroundColor(.white)
            }
            .padding(.leading, size * 0.1)
            .frame(width: size, height: size, alignment: .leading)
        }
    }
}

// MARK: - Logo Variations

struct AppLogoCircle: View {
    var size: CGFloat = 120
    
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 249/255, green: 115/255, blue: 22/255),
                            Color(red: 220/255, green: 38/255, blue: 38/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            
            VStack(spacing: size * 0.02) {
                Text("CBZ")
                    .font(.system(size: size * 0.12, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                
                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.1, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                
                Text("PDF")
                    .font(.system(size: size * 0.18, weight: .heavy))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Dark Mode Logo Variant

struct AppLogoDark: View {
    var size: CGFloat = 120
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(Color(red: 26/255, green: 26/255, blue: 46/255))
                .frame(width: size, height: size)
            
            VStack(alignment: .leading, spacing: size * 0.02) {
                Text("CBZ")
                    .font(.system(size: size * 0.15, weight: .heavy))
                    .foregroundColor(Color(red: 251/255, green: 146/255, blue: 60/255).opacity(0.9))
                
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(red: 249/255, green: 115/255, blue: 22/255).opacity(0.4))
                        .frame(height: 2)
                    
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: size * 0.1))
                        .foregroundColor(Color(red: 249/255, green: 115/255, blue: 22/255).opacity(0.9))
                }
                .frame(width: size * 0.65)
                
                Text("PDF")
                    .font(.system(size: size * 0.2, weight: .heavy))
                    .foregroundColor(Color(red: 249/255, green: 115/255, blue: 22/255))
            }
            .padding(.leading, size * 0.1)
            .frame(width: size, height: size, alignment: .leading)
        }
    }
}

// MARK: - Animated Logo (for splash screen)

struct AppLogoAnimated: View {
    var size: CGFloat = 120
    @State private var showCBZ = false
    @State private var showArrow = false
    @State private var showPDF = false
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 253/255, green: 186/255, blue: 116/255),
                            Color(red: 249/255, green: 115/255, blue: 22/255),
                            Color(red: 194/255, green: 65/255, blue: 12/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
            
            VStack(alignment: .leading, spacing: size * 0.02) {
                // CBZ text
                Text("CBZ")
                    .font(.system(size: size * 0.15, weight: .heavy))
                    .foregroundColor(.white.opacity(0.95))
                    .opacity(showCBZ ? 1 : 0)
                    .offset(x: showCBZ ? 0 : -20)
                
                // Divider line with arrow
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(height: 2)
                    
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: size * 0.1))
                        .foregroundColor(.white.opacity(0.9))
                }
                .frame(width: size * 0.65)
                .opacity(showArrow ? 1 : 0)
                .scaleEffect(x: showArrow ? 1 : 0, anchor: .leading)
                
                // PDF text
                Text("PDF")
                    .font(.system(size: size * 0.2, weight: .heavy))
                    .foregroundColor(.white)
                    .opacity(showPDF ? 1 : 0)
                    .offset(x: showPDF ? 0 : -20)
            }
            .padding(.leading, size * 0.1)
            .frame(width: size, height: size, alignment: .leading)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) {
                showCBZ = true
            }
            withAnimation(.easeOut(duration: 0.3).delay(0.5)) {
                showArrow = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.7)) {
                showPDF = true
            }
        }
    }
}

#Preview("Logo Sizes") {
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            AppLogo(size: 120)
            AppLogo(size: 80)
            AppLogo(size: 60)
            AppLogo(size: 40)
        }
        
        Text("Standard Logo at Different Sizes")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding()
    .background(Color(.systemBackground))
}

#Preview("Logo Variants") {
    HStack(spacing: 20) {
        VStack {
            AppLogo(size: 100)
            Text("Standard")
                .font(.caption)
        }
        VStack {
            AppLogoCircle(size: 100)
            Text("Circle")
                .font(.caption)
        }
        VStack {
            AppLogoDark(size: 100)
            Text("Dark")
                .font(.caption)
        }
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
