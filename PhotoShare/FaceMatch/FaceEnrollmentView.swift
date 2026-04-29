import PhotosUI
import SwiftUI

struct FaceEnrollmentView: View {
    @StateObject private var vm: FaceEnrollmentViewModel
    @Environment(\.dismiss) var dismiss

    init(friendId: UUID, friendName: String) {
        _vm = StateObject(wrappedValue: FaceEnrollmentViewModel(friendId: friendId, friendName: friendName))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if vm.isAlreadyEnrolled && !vm.enrollmentComplete {
                        alreadyEnrolledBanner
                    }

                    instructions

                    PhotosPicker(
                        selection: $vm.selectedItems,
                        maxSelectionCount: 5,
                        matching: .images
                    ) {
                        Label(
                            "Select Photos (\(vm.selectedItems.count) of 5)",
                            systemImage: "photo.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .onChange(of: vm.selectedItems) {
                        Task { await vm.loadPreviews() }
                    }

                    if !vm.previewImages.isEmpty {
                        previewGrid
                    }

                    if vm.enrollmentComplete {
                        successView
                    } else {
                        enrollButton
                    }
                }
                .padding()
            }
            .navigationTitle("Enroll \(vm.friendName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
    }

    // MARK: - Subviews

    private var alreadyEnrolledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("\(vm.friendName) is already enrolled. Select new photos to update.")
                .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select 3–5 photos of \(vm.friendName)")
                .font(.headline)
            Text("Choose photos where their face is clearly visible. Variety helps — different lighting, angles, and distances improve matching accuracy.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 8) {
            ForEach(Array(vm.previewImages.enumerated()), id: \.offset) { _, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var enrollButton: some View {
        Button {
            Task { await vm.enroll() }
        } label: {
            Group {
                if vm.isEnrolling {
                    ProgressView().tint(.white)
                } else {
                    Text(vm.isAlreadyEnrolled ? "Update Enrollment" : "Enroll Face")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(vm.canEnroll && !vm.isEnrolling ? Color.accentColor : Color.secondary.opacity(0.3))
            .foregroundStyle(vm.canEnroll && !vm.isEnrolling ? Color.white : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!vm.canEnroll || vm.isEnrolling)
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Enrollment complete!")
                .font(.title3.bold())
            Text("PhotoShare will now automatically detect \(vm.friendName) in your photos and share them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(.vertical, 32)
    }
}
