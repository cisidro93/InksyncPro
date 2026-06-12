import SwiftUI

struct PipelineSelector: View {
    @Binding var selectedPipeline: OutputPipeline
    let pdf: ConvertedPDF?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.inkTextSecondary)

            HStack(spacing: 8) {
                ForEach(OutputPipeline.allCases, id: \.self) { pipeline in
                    let vm = ConversionViewModel()
                    let disabled = pdf.map {
                        vm.pipelineIsDisabled(pipeline, for: $0, format: .epub)
                    } ?? false

                    Button {
                        if !disabled { selectedPipeline = pipeline }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: vm.pipelineIcon(for: pipeline))
                            Text(pipeline == .standard ? "Standard" : "Pro Panel")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(selectedPipeline == pipeline ? .white : .inkTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedPipeline == pipeline
                                ? vm.cardAccentColor(for: pipeline)
                                : Color.inkSurfaceRaised
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(disabled)
                    .opacity(disabled ? 0.4 : 1.0)
                }
            }

            // Subtitle for selected pipeline
            Text(ConversionViewModel().pipelineSubtitle(for: selectedPipeline))
                .font(.system(size: 11))
                .foregroundColor(.inkTextTertiary)
        }
    }
}
