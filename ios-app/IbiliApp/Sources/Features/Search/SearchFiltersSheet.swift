import SwiftUI

/// Filter sheet anchored to the trailing toolbar button on the search
/// results screen. Mirrors PiliPlus' implemented filter axes:
/// video = order/duration/zone, user = order/type, article = order/zone.
struct SearchFiltersSheet: View {
    @ObservedObject var vm: SearchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch vm.selectedType {
                case .video:
                    videoFilters
                case .user:
                    userFilters
                case .article:
                    articleFilters
                case .live:
                    Section {
                        Text("上游直播搜索没有额外筛选项")
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                case .bangumi, .movie:
                    EmptyView()
                }
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        vm.submit()
                        dismiss()
                    }
                    .foregroundStyle(IbiliTheme.accent)
                }
            }
            .tint(IbiliTheme.accent)
        }
    }

    @ViewBuilder
    private var videoFilters: some View {
        Section("排序方式") {
            Picker("排序", selection: $vm.order) {
                ForEach(SearchOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("时长") {
            Picker("时长", selection: $vm.durationFilter) {
                ForEach(SearchDuration.allCases) { d in
                    Text(d.label).tag(d)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        if let cat = vm.selectedCategory {
            Section("当前分区") {
                HStack {
                    Image(systemName: cat.systemImage)
                        .foregroundStyle(IbiliTheme.accent)
                    Text(cat.name)
                    Spacer()
                    Button("移除") { vm.selectedCategory = nil }
                        .foregroundStyle(IbiliTheme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var userFilters: some View {
        Section("用户粉丝数及等级排序顺序") {
            Picker("排序", selection: $vm.userOrder) {
                ForEach(SearchUserOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("用户分类") {
            Picker("分类", selection: $vm.userKind) {
                ForEach(SearchUserKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var articleFilters: some View {
        Section("排序") {
            Picker("排序", selection: $vm.articleOrder) {
                ForEach(SearchArticleOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("分区") {
            Picker("分区", selection: $vm.articleZone) {
                ForEach(SearchArticleZone.allCases) { zone in
                    Text(zone.label).tag(zone)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
