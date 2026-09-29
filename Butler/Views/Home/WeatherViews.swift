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

/// Pulled up from the greeting: today's weather, the next days, and where the weather is for.
/// A sheet with a handle; swipe down to close.
struct WeatherPanel: View {
    @Environment(\.openURL) private var openURL
    @State private var city = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false
    @State private var searchError: String?
    @FocusState private var typingCity: Bool
    private var weather: WeatherStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                current
                if let snapshot = weather.snapshot, !snapshot.days.isEmpty { forecast(snapshot) }
                location
                if let snapshot = weather.snapshot {
                    WeatherAttributionView(snapshot: snapshot)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { ButlerBackground() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await weather.refresh(force: true, requestPermission: true) }
    }

    // MARK: Now

    private var current: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = weather.snapshot {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: snapshot.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 46))
                        .frame(width: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(Int(snapshot.temperature.rounded()))°")
                                .font(.system(size: 44, weight: .semibold)).monospacedDigit()
                            Text(snapshot.conditionLabel).font(.title3.weight(.medium))
                        }
                        Text("体感 \(Int(snapshot.feelsLike.rounded()))° · 风速 \(Int(snapshot.windKPH.rounded())) km/h")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let hint = snapshot.hint() {
                    Text(hint).font(.body).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(snapshot.alerts) { alert in
                    Link(destination: alert.url) {
                        Label(alert.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "location.fill").font(.caption2)
                    Text(snapshot.place.name)
                    Text("·")
                    Text(updatedLabel(snapshot))
                    Spacer(minLength: 8)
                    refreshButton
                }
                .font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    if weather.isRefreshing { ProgressView() }
                    Text(weather.isRefreshing ? "正在获取天气…" : (weather.error ?? "还没有天气数据"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    refreshButton
                }
            }
            if weather.snapshot != nil, let error = weather.error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var refreshButton: some View {
        Button {
            Task { await weather.refresh(force: true, requestPermission: true) }
        } label: {
            if weather.isRefreshing { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise").font(.footnote.weight(.semibold)) }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 32)
        .contentShape(Rectangle())
        .disabled(weather.isRefreshing)
        .accessibilityLabel("刷新天气")
    }

    private func updatedLabel(_ snapshot: WeatherSnapshot) -> String {
        let time = snapshot.fetchedAt.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))
        return snapshot.isFresh() ? "\(time) 更新" : "\(time) 的数据，下拉刷新"
    }

    // MARK: Next days

    private func forecast(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未来几天").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 6)
            VStack(spacing: 0) {
                ForEach(Array(snapshot.days.enumerated()), id: \.element.id) { index, day in
                    HStack(spacing: 12) {
                        Text(Self.dayName(day.date, index: index, timeZone: snapshot.place.timeZoneIdentifier))
                            .frame(width: 72, alignment: .leading)
                        Image(systemName: day.symbol).symbolRenderingMode(.multicolor)
                            .frame(width: 28).accessibilityLabel(day.condition)
                        Text(day.rainChance >= 0.2 ? "\(Int((day.rainChance * 100).rounded()))%" : "")
                            .font(.footnote).foregroundStyle(.blue).monospacedDigit()
                            .frame(width: 40, alignment: .leading)
                        Spacer(minLength: 4)
                        Text("\(Int(day.low.rounded()))°").foregroundStyle(.secondary).monospacedDigit()
                        Text("\(Int(day.high.rounded()))°").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 46)
                    if index < snapshot.days.count - 1 { RowDivider(inset: 16) }
                }
            }
            .padding(.vertical, 4)
            .glassCard()
        }
    }

    static func dayName(_ date: Date, index: Int, timeZone: String?) -> String {
        if index == 0 { return "今天" }
        if index == 1 { return "明天" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    // MARK: Where

    private var location: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("天气位置").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 6)
            VStack(spacing: 0) {
                placeRow("使用手机定位", systemImage: "location", selected: weather.selection.city == nil) {
                    choose(WeatherLocation())
                }
                if let chosen = weather.selection.city {
                    RowDivider(inset: 52)
                    placeRow(chosen.name, systemImage: "building.2", selected: true) {}
                }
                RowDivider(inset: 52)
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 24)
                    TextField("搜索城市或地区", text: $city)
                        .focused($typingCity)
                        .submitLabel(.search).onSubmit(search)
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 16).frame(minHeight: 48)
                ForEach(results) { place in
                    RowDivider(inset: 52)
                    placeRow(place.name, systemImage: "mappin.and.ellipse", selected: false) {
                        choose(WeatherLocation(city: place))
                    }
                }
                if let searchError {
                    RowDivider(inset: 52)
                    Text(searchError).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 52).padding(.trailing, 16).frame(minHeight: 44)
                }
            }
            .padding(.vertical, 4)
            .glassCard()
            VStack(alignment: .leading, spacing: 6) {
                Text("只在查看天气时获取大致位置，不在后台定位。换城市后，首页提醒和对话都会用新位置。")
                Button("定位不准？打开系统定位设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.top, 2)
        }
    }

    private func placeRow(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 24).foregroundStyle(.secondary)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func search() {
        guard !searching, city.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
        searching = true; searchError = nil; results = []
        Task { @MainActor in
            defer { searching = false }
            do { results = try await weather.search(city); if results.isEmpty { searchError = "没有找到，请补充省份或国家。" } }
            catch { searchError = "城市查找失败，请稍后重试。" }
        }
    }

    private func choose(_ location: WeatherLocation) {
        do { try weather.setLocation(location); results = []; city = ""; typingCity = false }
        catch { searchError = error.localizedDescription; return }
        Task { await weather.refresh(force: true, requestPermission: true) }
    }
}

/// Apple Weather's required attribution: its mark (kept small) and a link to the data sources.
struct WeatherAttributionView: View {
    let snapshot: WeatherSnapshot
    var showsLabel = true
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Link(destination: snapshot.legalURL) {
            HStack(spacing: 6) {
                AsyncImage(url: colorScheme == .dark ? snapshot.darkMark : snapshot.lightMark) { image in
                    image.resizable().scaledToFit()
                } placeholder: { Label("Weather", systemImage: "apple.logo").font(.caption2) }
                    .frame(height: 12)
                if showsLabel { Text("数据来源").font(.caption2).underline() }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Apple Weather 数据来源")
    }
}
