import HermesBotUI
import SwiftUI

/// Every shape and colour, for checking the avatar art. Opened with `--avatars`.
struct AvatarGallery: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 28) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70)), count: 5), spacing: 18) {
                ForEach(AvatarShape.allCases, id: \.self) { shape in
                    BotAvatar(AvatarLook(shape: shape, color: .green), size: 56)
                }
            }
            HStack(spacing: 14) {
                ForEach(Array(zip(AvatarShape.allCases, AvatarColor.allCases)), id: \.1) { shape, color in
                    BotAvatar(
                        AvatarLook(shape: shape, color: color),
                        size: 40,
                        isWorking: CommandLine.arguments.contains("--working")
                    )
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme(scheme).surface)
        .avatarsFollowPointer()
        .ignoresSafeArea()
    }
}
