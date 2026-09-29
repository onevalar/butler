import SwiftUI

struct WeatherGreeting: View {
    let greeting: String
    @State private var showingWeather = false
    private var weather: WeatherStore { .shared }
    var body: some View {
        Button { showingWeather = true } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { Text(greeting); weatherLabel }
                VStack(alignment: .leading, spacing: 4) { Text(greeting); weatherLabel }
            }.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("打开天气并刷新，也可以更换城市")
            .sheet(isPresented: $showingWeather) { WeatherPanel() }
            .task { await weather.refresh() }
    }
    private var weatherLabel: some View {
        HStack(spacing: 4) {
            Text(weather.snapshot.map { $0.conditionLabel + ($0.isFresh() ? "" : " · 待更新") } ?? "天气")
        }
    }
}

struct WeatherPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var city = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false
    @State private var searchError: String?
    private var weather: WeatherStore { .shared }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let snapshot = weather.snapshot {
                        HStack {
                            Image(systemName: snapshot.symbol).font(.largeTitle)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.place.name).font(.headline)
                                Text(snapshot.shortLabel).font(.title2)
                                Text("体感 \(Int(snapshot.feelsLike.rounded()))° · 风速 \(Int(snapshot.windKPH.rounded())) km/h")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) 更新\(snapshot.isFresh() ? "" : " · 缓存数据，需刷新")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let hint = snapshot.hint() { Text(hint) }
                        ForEach(snapshot.alerts) { alert in Link(alert.text, destination: alert.url) }
                        WeatherAttributionView(snapshot: snapshot)
                    }
                    if weather.isRefreshing { Label("正在更新天气…", systemImage: "cloud") }
                    if let error = weather.error { Text(error).foregroundStyle(.secondary) }
                    Button("刷新天气") { Task { await weather.refresh(force: true, requestPermission: true) } }.disabled(weather.isRefreshing)
                } header: { Text(weather.selection.label) }
                if let snapshot = weather.snapshot {
                    Section("未来天气") {
                        ForEach(snapshot.days) { day in
                            HStack {
                                Text(snapshot.dayLabel(day.date)).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: day.symbol).accessibilityLabel(day.condition)
                                Text("\(Int(day.rainChance * 100))%").font(.caption).foregroundStyle(.secondary)
                                Text("\(Int(day.low.rounded()))° – \(Int(day.high.rounded()))°").monospacedDigit()
                            }
                        }
                    }
                }
                Section {
                    Button { choose(WeatherLocation()) } label: {
                        Label("使用手机定位", systemImage: "location")
                    }
                    HStack {
                        TextField("手动搜索城市或地区", text: $city).submitLabel(.search).onSubmit(search)
                        Button("搜索", action: search).disabled(searching || city.trimmingCharacters(in: .whitespaces).count < 2)
                    }
                    if searching { Text("正在查找…").foregroundStyle(.secondary) }
                    if let searchError { Text(searchError).foregroundStyle(.secondary) }
                    ForEach(results) { place in Button(place.name) { choose(WeatherLocation(city: place)) } }
                    Button("打开系统定位设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } header: { Text("天气位置") } footer: {
                    Text("使用天气时才获取大致位置，不在后台持续定位。更换城市后，首页提醒与对话会一起使用新位置。")
                }
            }.navigationTitle("天气").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await weather.refresh(force: true, requestPermission: true) }
        }
    }
    private func search() {
        guard !searching else { return }
        searching = true; searchError = nil; results = []
        Task { @MainActor in
            defer { searching = false }
            do { results = try await weather.search(city); if results.isEmpty { searchError = "没有找到，请补充省份或国家。" } }
            catch { searchError = "城市查找失败，请稍后重试。" }
        }
    }
    private func choose(_ location: WeatherLocation) {
        do { try weather.setLocation(location); results = []; city = "" }
        catch { searchError = error.localizedDescription; return }
        Task { await weather.refresh(force: true, requestPermission: true) }
    }
}

struct WeatherAttributionView: View {
    let snapshot: WeatherSnapshot
    var showsLabel = true
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Link(destination: snapshot.legalURL) {
            HStack(spacing: 8) {
                AsyncImage(url: colorScheme == .dark ? snapshot.darkMark : snapshot.lightMark) { image in
                    image.resizable().scaledToFit()
                } placeholder: { Label("Weather", systemImage: "apple.logo") }
                    .frame(width: 96, height: 20)
                if showsLabel { Text("天气数据来源").font(.caption) }
            }
        }
        .accessibilityLabel("Apple Weather 数据来源")
    }
}
