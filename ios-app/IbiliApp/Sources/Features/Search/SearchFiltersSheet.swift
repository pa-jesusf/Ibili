import SwiftUI

/// Filter sheet opened from the shared result category bar on the search
/// results screen. Mirrors PiliPlus' implemented filter axes:
/// video = order/duration/zone, user = order/type, article = order/zone.
struct SearchFiltersSheet: View {
    @ObservedObject var vm: SearchViewModel
    @State private var selection: SearchFilterSelection
    @Environment(\.dismiss) private var dismiss

    init(vm: SearchViewModel) {
        self.vm = vm
        _selection = State(initialValue: vm.filterSelection)
    }

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
                        vm.applyFilters(selection)
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
            Picker("排序", selection: $selection.order) {
                ForEach(SearchOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("时长") {
            Picker("时长", selection: $selection.duration) {
                ForEach(SearchDuration.allCases) { d in
                    Text(d.label).tag(d)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("分区") {
            Picker("分区", selection: $selection.category) {
                Text("全部分区").tag(nil as SearchCategory?)
                ForEach(SearchCategories.all) { category in
                    Label(category.name, systemImage: category.systemImage)
                        .tag(Optional(category))
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var userFilters: some View {
        Section("用户粉丝数及等级排序顺序") {
            Picker("排序", selection: $selection.userOrder) {
                ForEach(SearchUserOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("用户分类") {
            Picker("分类", selection: $selection.userKind) {
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
            Picker("排序", selection: $selection.articleOrder) {
                ForEach(SearchArticleOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("分区") {
            Picker("分区", selection: $selection.articleZone) {
                ForEach(SearchArticleZone.allCases) { zone in
                    Text(zone.label).tag(zone)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
