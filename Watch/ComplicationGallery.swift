import SwiftUI

// 只在手表 app 里编（表盘扩展不带 LaneSignal：它只进 application target）。
/// 手表 app 里的预览页：把四种复杂功能按表盘上的大小摆出来，给模拟器截图核对（表盘本身在模拟器上配不了）。
struct ComplicationGallery: View {
    let snapshot: WatchSnapshot?

    var body: some View {
        let state = NextLessonState(date: Date(), snapshot: snapshot)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    NextCircular(state: state)
                        .frame(width: 50, height: 50)
                    NextCorner(state: state)
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())        // 表盘四角是圆形槽位；预览里同样裁圆
                    Spacer(minLength: 0)
                }
                NextRectangular(state: state)
                    .padding(8)
                    .frame(height: 70)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                NextInline(state: state)
                    .font(.footnote)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("表盘")
        .onAppear { LaneSignal.ready("watch-complications") }
    }
}
