#if DEBUG
import PhotosUI
import SwiftUI

struct FaceMatchSandboxView: View {

    @StateObject private var vm = FaceMatchSandboxViewModel()

    var body: some View {
        List {
            enrollmentSection
            testSection
            if !vm.distanceResults.isEmpty {
                resultsSection
            }
        }
        .navigationTitle("Face Match Sandbox")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if vm.isProcessing {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Sections

    private var enrollmentSection: some View {
        Section {
            PhotosPicker(
                selection: $vm.enrollmentPickerItems,
                maxSelectionCount: 5,
                matching: .images
            ) {
                Label("Select Enrollment Photos (1–5)", systemImage: "person.crop.square.fill")
            }
            .onChange(of: vm.enrollmentPickerItems) {
                Task { await vm.loadEnrollmentImages() }
            }

            if !vm.enrollmentImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(vm.enrollmentImages.enumerated()), id: \.offset) { index, image in
                            imageThumbnail(image, faceCount: vm.enrollmentFaceCounts[safe: index]) {
                                Task { await vm.removeEnrollmentImage(at: index) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Enrollment Photos")
        } footer: {
            if !vm.enrollmentImages.isEmpty {
                let detected = vm.enrollmentFaceCounts.filter { $0 > 0 }.count
                Text("\(detected)/\(vm.enrollmentImages.count) photos have a detectable face")
            }
        }
    }

    private var testSection: some View {
        Section {
            PhotosPicker(
                selection: $vm.testPickerItem,
                maxSelectionCount: 1,
                matching: .images
            ) {
                Label("Select Test Photo", systemImage: "photo")
            }
            .onChange(of: vm.testPickerItem) {
                Task { await vm.loadTestImage() }
            }

            if let testImage = vm.testImage {
                HStack(spacing: 12) {
                    imageThumbnail(testImage, faceCount: vm.testFaceCount) {
                        vm.removeTestImage()
                    }
                    VStack(alignment: .leading) {
                        Text("\(vm.testFaceCount) face(s) detected")
                            .font(.subheadline)
                        if vm.testFaceCount == 0 {
                            Text("No faces found — matching won't run.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Test Photo")
        }
    }

    private var resultsSection: some View {
        Section {
            VStack(spacing: 16) {
                matchLabel

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Threshold")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("0.1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $vm.threshold, in: 0.1...2.0, step: 0.01)
                        Text("2.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(format: "Current: %.2f  (default: %.2f)", vm.threshold, FaceDetector.defaultMatchThreshold))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairwise Distances (sorted)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(Array(vm.distanceResults.enumerated()), id: \.element.id) { index, result in
                        HStack(spacing: 10) {
                            // Enrollment photo thumbnail
                            if let img = vm.enrollmentImages[safe: result.enrollmentImageIndex] {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 36, height: 36)
                                    .clipped()
                                    .cornerRadius(5)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5)
                                    )
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                // Only show face index label when there are multiple test faces
                                if vm.testFaceCount > 1 {
                                    Text("Face \(result.testFaceIndex + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(String(format: "%.4f", result.distance))
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(index == 0 ? .bold : .regular)
                            }

                            if index == 0 {
                                Text("← min")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: result.distance < vm.threshold ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(result.distance < vm.threshold ? .green : .secondary)
                        }
                    }
                }

                Text("Lower distance = closer match. Values < threshold trigger a share.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Results")
        }
    }

    // MARK: - Subviews

    private var matchLabel: some View {
        let matched = vm.isMatch(at: vm.threshold)
        return HStack {
            Image(systemName: matched ? "checkmark.seal.fill" : "xmark.seal")
                .font(.title)
                .foregroundStyle(matched ? .green : .red)
            Text(matched ? "MATCH" : "NO MATCH")
                .font(.title2.bold())
                .foregroundStyle(matched ? .green : .red)
            if let min = vm.minDistance {
                Spacer()
                Text(String(format: "min dist: %.4f", min))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func imageThumbnail(_ image: UIImage, faceCount: Int?, onRemove: @escaping () -> Void) -> some View {
        let count = faceCount ?? 0
        return ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 80)
                .clipped()
                .cornerRadius(8)

            VStack {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .offset(x: 6, y: -6)

                Spacer()
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(count)")
                        .font(.caption2.bold())
                        .padding(4)
                        .background(count > 0 ? Color.green : Color.red, in: Circle())
                        .foregroundStyle(.white)
                        .offset(x: 6, y: 6)
                }
            }
        }
        .frame(width: 80, height: 80)
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    NavigationStack {
        FaceMatchSandboxView()
    }
}
#endif
