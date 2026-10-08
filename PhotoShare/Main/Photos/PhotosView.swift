import SwiftUI

struct PhotosView: View {
    @EnvironmentObject var vm: PhotosViewModel
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        OttoEyebrow(text: "Photos")
                        Text("For you")
                            .font(OttoFont.serifBold(size: 32))
                            .foregroundStyle(OttoColor.ink)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)

                // content
                if vm.isLoading {
                    Spacer()
                    ProgressView().tint(OttoColor.sage)
                    Spacer()
                } else if vm.photos.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(groupedPhotos, id: \.senderName) { group in
                                PolaroidStackGroupView(group: group)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("photos.stack.\(group.senderName)")
                                    .padding(.bottom, 26)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            OttoMascot(pose: .sleeping, width: 200)
                .accessibilityIdentifier("photos.empty")
            VStack(spacing: 8) {
                Text("Otto's keeping watch.")
                    .font(OttoFont.serifBoldItalic(size: 24))
                    .foregroundStyle(OttoColor.ink)
                Text("When friends share photos with you, they'll arrive here.")
                    .font(.system(size: 15))
                    .foregroundStyle(OttoColor.bark)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
    }

    // Group received photos by sender
    private var groupedPhotos: [SenderGroup] {
        var dict: [String: SenderGroup] = [:]
        var order: [String] = []
        for photo in vm.photos {
            let name = photo.photos.sender.displayName
            if dict[name] == nil {
                dict[name] = SenderGroup(senderName: name, photos: [])
                order.append(name)
            }
            dict[name]?.photos.append(photo)
        }
        return order.compactMap { dict[$0] }
    }
}

// MARK: - Data model for grouping

struct SenderGroup {
    let senderName: String
    var photos: [ReceivedPhoto]
}

// MARK: - Polaroid Stack Group

struct PolaroidStackGroupView: View {
    let group: SenderGroup

    @State private var topIndex: Int = 0
    @State private var dragOffset: CGFloat = 0
    @State private var isFlying: Bool = false
    @State private var flyDirection: CGFloat = 1
    @GestureState private var isDragging: Bool = false

    private let cardWidth: CGFloat = 220
    private let stackHeight: CGFloat = 320

    private var total: Int { group.photos.count }

    var body: some View {
        VStack(spacing: 0) {
            // sender header
            HStack(spacing: 10) {
                OttoAvatarCircle(name: group.senderName, size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.senderName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OttoColor.ink)
                        if group.photos.contains(where: { !$0.isSaved }) {
                            Text("\(group.photos.filter { !$0.isSaved }.count) new")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OttoColor.sage)
                                .clipShape(Capsule())
                        }
                    }
                    Text(group.photos.first?.photos.takenAt.formatted(.relative(presentation: .named)) ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(OttoColor.barkSoft)
                }

                Spacer()

                Button("Save all") {}
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OttoColor.sage)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            // polaroid stack
            ZStack {
                ForEach(stackIndices, id: \.self) { stackPos in
                    let photoIndex = (topIndex + stackPos) % total
                    let photo = group.photos[photoIndex]
                    let isTop = stackPos == 0
                    let tilt = tiltForIndex(photoIndex)

                    PolaroidCard(
                        photo: photo,
                        showCaption: isTop,
                        tilt: isTop ? tilt + (dragOffset + (isFlying ? flyDirection * 360 : 0)) * 0.05 : tilt * 0.6,
                        offsetX: isTop ? dragOffset + (isFlying ? flyDirection * 360 : 0) : 0,
                        offsetY: CGFloat(stackPos) * 6,
                        scale: 1.0 - CGFloat(stackPos) * 0.04,
                        opacity: opacityForPosition(stackPos),
                        isInteractive: isTop
                    )
                    .zIndex(Double(100 - stackPos))
                    .animation(
                        (isDragging && isTop) ? nil : .spring(response: 0.26, dampingFraction: 0.85),
                        value: dragOffset
                    )
                    .animation(
                        .spring(response: 0.26, dampingFraction: 0.85),
                        value: isFlying
                    )
                }

                // counter pill
                HStack(spacing: 8) {
                    Text("\(topIndex + 1) / \(total)")
                        .font(.system(size: 11))
                        .foregroundStyle(OttoColor.barkSoft)
                    Text("·")
                        .foregroundStyle(OttoColor.lineSoft)
                    Text("swipe")
                        .font(OttoFont.serifBold(size: 11))
                        .italic()
                        .foregroundStyle(OttoColor.barkSoft)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(OttoColor.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(OttoColor.lineSoft, lineWidth: 0.5))
                .offset(y: stackHeight / 2 - 18)
                .zIndex(200)

                // nav arrows
                HStack {
                    Button { advance(dir: -1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OttoColor.bark)
                            .frame(width: 30, height: 30)
                            .background(OttoColor.surface)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(OttoColor.lineSoft, lineWidth: 0.5))
                    }
                    Spacer()
                    Button { advance(dir: 1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OttoColor.bark)
                            .frame(width: 30, height: 30)
                            .background(OttoColor.surface)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(OttoColor.lineSoft, lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 6)
                .offset(y: -20)
                .zIndex(200)
            }
            .frame(height: stackHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 10)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        if abs(value.translation.width) > 70 {
                            advance(dir: value.translation.width > 0 ? 1 : -1)
                        } else {
                            withAnimation(.spring(response: 0.2)) { dragOffset = 0 }
                        }
                    }
            )
        }
    }

    private var stackIndices: [Int] {
        (0..<min(total, 4)).map { $0 }
    }

    private func tiltForIndex(_ idx: Int) -> CGFloat {
        let tilts: [CGFloat] = [-4, 3, -2.5, 4, -3.5, 2, -4.5]
        return tilts[idx % tilts.count]
    }

    private func opacityForPosition(_ pos: Int) -> Double {
        switch pos {
        case 0: return 1.0
        case 1: return 0.95
        case 2: return 0.75
        case 3: return 0.45
        default: return 0
        }
    }

    private func advance(dir: CGFloat) {
        guard !isFlying else { return }
        flyDirection = dir
        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            isFlying = true
        } completion: {
            topIndex = (topIndex + 1) % total
            dragOffset = 0
            isFlying = false
        }
    }
}

// MARK: - Single Polaroid Card

struct PolaroidCard: View {
    let photo: ReceivedPhoto
    let showCaption: Bool
    let tilt: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let scale: CGFloat
    let opacity: Double
    let isInteractive: Bool

    var body: some View {
        VStack(spacing: 0) {
            // top polaroid border
            Color.clear.frame(height: 10)

            // photo area
            Group {
                if let url = photo.photos.publicURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            Rectangle().fill(OttoColor.cream)
                        }
                    }
                } else {
                    Rectangle().fill(OttoColor.cream)
                }
            }
            .frame(width: 200, height: 200)
            .clipped()
            .clipShape(Rectangle())
            .overlay(
                LinearGradient(
                    colors: [Color(hex: "#FFF0D2").opacity(0.06), Color(hex: "#46281A").opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // caption area
            ZStack {
                if showCaption {
                    Text(photo.photos.takenAt.formatted(.relative(presentation: .named)))
                        .font(OttoFont.serifBold(size: 14))
                        .italic()
                        .foregroundStyle(Color(hex: "#6B533A"))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                }
            }
            .frame(height: 36)

            // expiry warning
            if photo.photos.isExpiringSoon && showCaption {
                Text("Expires soon — save it")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(OttoColor.wax)
                    .clipShape(Capsule())
                    .padding(.bottom, 6)
            }
        }
        .frame(width: 220)
        .background(Color(hex: "#FBF6E9"))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: Color(hex: "#3C2814").opacity(0.30), radius: 14, x: 0, y: 10)
        .shadow(color: Color(hex: "#3C2814").opacity(0.10), radius: 4, x: 0, y: 2)
        .rotationEffect(.degrees(tilt))
        .offset(x: offsetX, y: offsetY)
        .scaleEffect(scale)
        .opacity(opacity)
        .allowsHitTesting(isInteractive)
    }
}
