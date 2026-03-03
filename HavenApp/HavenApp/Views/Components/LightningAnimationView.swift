import SwiftUI

struct LightningAnimationView: View {
    @Binding var isAnimating: Bool
    
    @State private var flashOpacity: Double = 0
    @State private var boltOpacity1: Double = 0
    @State private var boltOpacity2: Double = 0
    @State private var boltOffset: CGFloat = -50
    
    var body: some View {
        ZStack {
            // Screen flash
            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
            
            // Primary Bolt
            LightningShape()
                .stroke(Color.white, lineWidth: 5)
                .shadow(color: .yellow, radius: 15)
                .blendMode(.screen)
                .opacity(boltOpacity1)
                .offset(y: boltOffset)
            
            // Secondary Bolt (offset slightly)
            LightningShape()
                .stroke(Color.yellow, lineWidth: 2)
                .shadow(color: .orange, radius: 10)
                .opacity(boltOpacity2)
                .offset(x: 20, y: boltOffset + 20)
        }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                triggerAnimation()
            }
        }
    }
    
    private func triggerAnimation() {
        // Glorious multi-stage sequence
        
        // Stage 1: Pre-flash
        withAnimation(.easeIn(duration: 0.05)) {
            flashOpacity = 0.4
        }
        
        // Stage 2: Primary strike
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.spring(response: 0.1, dampingFraction: 0.5)) {
                boltOpacity1 = 1.0
                boltOffset = 0
                flashOpacity = 0.6
            }
        }
        
        // Stage 3: Secondary strike and flicker
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            boltOpacity2 = 0.8
            withAnimation(.easeInOut(duration: 0.05).repeatCount(4, autoreverses: true)) {
                boltOpacity1 = 0.3
                flashOpacity = 0.2
            }
        }
        
        // Stage 4: Fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.5)) {
                boltOpacity1 = 0
                boltOpacity2 = 0
                flashOpacity = 0
                boltOffset = 200
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isAnimating = false
                boltOffset = -50
            }
        }
    }
}

struct LightningShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        
        path.move(to: CGPoint(x: width * 0.6, y: 0))
        path.addLine(to: CGPoint(x: width * 0.3, y: height * 0.4))
        path.addLine(to: CGPoint(x: width * 0.7, y: height * 0.35))
        path.addLine(to: CGPoint(x: width * 0.2, y: height * 0.75))
        path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.7))
        path.addLine(to: CGPoint(x: width * 0.1, y: height))
        
        return path
    }
}

#Preview {
    ZStack {
        Color.black
        LightningAnimationView(isAnimating: .constant(true))
    }
}
