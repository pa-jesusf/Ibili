import SwiftUI

struct EpisodeRail<Item: Identifiable, Content: View>: View where Item.ID: Hashable {
    let items: [Item]
    let currentID: Item.ID?
    var spacing: CGFloat = 8
    var verticalPadding: CGFloat = 2
    let content: (Int, Item) -> Content

    init(
        items: [Item],
        currentID: Item.ID? = nil,
        spacing: CGFloat = 8,
        verticalPadding: CGFloat = 2,
        @ViewBuilder content: @escaping (Int, Item) -> Content
    ) {
        self.items = items
        self.currentID = currentID
        self.spacing = spacing
        self.verticalPadding = verticalPadding
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        content(index + 1, item)
                            .id(item.id)
                    }
                }
                .padding(.vertical, verticalPadding)
            }
            .background(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: true))
            .overlay(PlayerSwipeBackExclusionZone(includeEnclosingScrollView: false))
            .onAppear {
                scrollToCurrent(proxy, animated: false)
            }
            .onChange(of: currentID) { _ in
                scrollToCurrent(proxy, animated: true)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let currentID else { return }
        let work = {
            proxy.scrollTo(currentID, anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                work()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                work()
            }
        }
    }
}
