import SwiftUI

/// Filter sheet anchored to the trailing toolbar button on the search
/// results screen. Presents the two implemented filter axes (sort
/// order + duration bucket); the zone filter is set by tapping into
/// search via the landing screen, so it isn't reproduced here.
struct SearchFiltersSheet: View {
    @ObservedObject var vm: SearchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
}
