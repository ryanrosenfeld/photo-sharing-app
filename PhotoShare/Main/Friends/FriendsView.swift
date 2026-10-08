import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var vm: FriendsViewModel
    @State private var showAddFriend = false

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        OttoEyebrow(text: "Friends")
                        Text("Your circle")
                            .font(OttoFont.serifBold(size: 32))
                            .foregroundStyle(OttoColor.ink)
                    }
                    Spacer()
                    Button {
                        showAddFriend = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(OttoColor.sage)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)

                if vm.isLoading {
                    Spacer()
                    ProgressView().tint(OttoColor.sage)
                    Spacer()
                } else if vm.outgoingLinks.isEmpty && vm.pendingRequests.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            // pending request card
                            if !vm.pendingRequests.isEmpty {
                                friendRequestCard
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 16)
                            }

                            // friends list
                            if !vm.outgoingLinks.isEmpty {
                                friendsList
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 8)
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
        .sheet(isPresented: $showAddFriend) {
            AddFriendSheet()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            OttoMascot(pose: .friends, width: 240)
            VStack(spacing: 8) {
                Text("Better with friends.")
                    .font(OttoFont.serifBoldItalic(size: 24))
                    .foregroundStyle(OttoColor.ink)
                Text("Send an invite. Once they accept, photos start flowing both ways.")
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.bark)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 40)
            }
            Button {
                showAddFriend = true
            } label: {
                Label("Add your first friend", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 13)
                    .background(OttoColor.sage)
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    // MARK: - Friend request card

    private var friendRequestCard: some View {
        OttoSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                OttoEyebrow(text: "\(vm.pendingRequests.count) friend request\(vm.pendingRequests.count > 1 ? "s" : "")")
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                ForEach(vm.pendingRequests) { request in
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            OttoAvatarCircle(name: request.sender.displayName, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.sender.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(OttoColor.ink)
                                Text("wants to be friends")
                                    .font(.system(size: 13))
                                    .foregroundStyle(OttoColor.bark)
                            }
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await vm.acceptRequest(request) }
                            } label: {
                                Text("Accept")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(OttoColor.sage)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                            Button {
                                Task { await vm.declineRequest(request) }
                            } label: {
                                Text("Decline")
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .foregroundStyle(OttoColor.bark)
                                    .overlay(
                                        Capsule().stroke(OttoColor.line, lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Friends list

    private var friendsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(vm.outgoingLinks.count) friend\(vm.outgoingLinks.count != 1 ? "s" : "")")
                .font(.system(size: 12, weight: .semibold))
                .kerning(1.4)
                .textCase(.uppercase)
                .foregroundStyle(OttoColor.barkSoft)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            OttoSectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(vm.outgoingLinks.enumerated()), id: \.element.id) { idx, link in
                        FriendRow(link: link)

                        if idx < vm.outgoingLinks.count - 1 {
                            Divider()
                                .background(OttoColor.line)
                                .padding(.leading, 70)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Friend row

private struct FriendRow: View {
    let link: OutgoingLink

    var body: some View {
        HStack(spacing: 12) {
            OttoAvatarCircle(name: link.recipient.displayName, size: 42)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(link.recipient.displayName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(OttoColor.ink)
                    if link.isPaused {
                        HStack(spacing: 4) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 7))
                            Text("Not reaching")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(OttoColor.barkSoft)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(OttoColor.chip)
                        .clipShape(Capsule())
                    }
                }
                Text(link.isPaused ? "Send off" : "Active")
                    .font(.system(size: 13))
                    .foregroundStyle(OttoColor.barkSoft)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OttoColor.barkSoft.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Add friend sheet (simplified)

struct AddFriendSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 17))
                        .foregroundStyle(OttoColor.sage)
                    Spacer()
                    Text("Add a friend")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OttoColor.ink)
                    Spacer()
                    Color.clear.frame(width: 50)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                Spacer()

                VStack(spacing: 24) {
                    OttoMascot(pose: .floating, width: 180)

                    VStack(spacing: 12) {
                        Text("Send them a link.")
                            .font(OttoFont.serifBoldItalic(size: 26))
                            .foregroundStyle(OttoColor.ink)

                        Text("They install otto and accept. Recognition sets itself up — photos start flowing the moment they do.")
                            .font(.system(size: 15))
                            .foregroundStyle(OttoColor.bark)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .padding(.horizontal, 20)
                    }

                    // link card
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 14))
                            .foregroundStyle(OttoColor.barkSoft)
                        Text("otto.app/i/join-xxxxxx")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(OttoColor.bark)
                            .lineLimit(1)
                        Spacer()
                        Text("Copy")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OttoColor.sage)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(OttoColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(OttoColor.lineSoft, lineWidth: 0.5)
                    )
                    .padding(.horizontal, 28)
                }

                Spacer()

                OttoPillButton(title: "Share invite") {}
                    .padding(.horizontal, 28)
                    .padding(.bottom, 36)
            }
        }
    }
}
