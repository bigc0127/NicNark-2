import SwiftUI
import CoreData

// MARK: - Lightweight projection of Core Data row
public struct PouchEvent: Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let removedAt: Date   // removalTime or fallback to insertionTime
    public let nicotineMg: Double
}

struct HourBucket: Identifiable, Hashable {
    let id = UUID()
    let hourStart: Date
    let events: [PouchEvent]
}

// MARK: - ViewModel
@MainActor
final class UsageGraphViewModel: ObservableObject {
    @Published var events: [PouchEvent] = []
    @Published var streakDays: Int = 0

    // “Since last pouch” fallback (when no active pouch)
    @Published private(set) var sinceLastPhrase: String = "0 hours 00 mins"
    @Published private(set) var sinceLastHH: Int = 0
    @Published private(set) var sinceLastMM: Int = 0

    // Active pouch state (header switches to “Pouch is currently in”)
    @Published private(set) var hasActivePouch: Bool = false
    @Published private(set) var activeElapsedPhrase: String = "00:00"

    private var timer: Timer?
    private let calendar = Calendar.current

    // A lightweight way for VM to ask for the current NSManagedObjectContext when the timer ticks.
    static var contextProvider: (() -> NSManagedObjectContext)?

    deinit { timer?.invalidate() }

    func setEvents(_ items: [PouchLog], context: NSManagedObjectContext) {
        // Convert Core Data rows into lightweight events
        let converted: [PouchEvent] = items.compactMap { row in
            guard let insertion = row.insertionTime else { return nil }
            let ts = row.removalTime ?? insertion
            let eventId = row.pouchId ?? UUID()
            let mg = max(0, row.nicotineAmount)
            let title = String(format: "%.0fmg Pouch", mg)
            return PouchEvent(id: eventId, name: title, removedAt: ts, nicotineMg: mg)
        }

        // Filter last 24 hours and sort newest first
        let now = Date()
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let filtered = converted.filter { $0.removedAt >= cutoff && $0.removedAt <= now }
        events = filtered.sorted { $0.removedAt > $1.removedAt }

        // For this view, “streakDays” mirrors your original: count in the last 24 hours
        streakDays = filtered.count

        recomputeTimeSinceLast()
        startTimerIfNeeded()

        // Refresh active pouch state
        let (active, elapsed) = fetchHasActivePouch(context: context)
        hasActivePouch = active
        if let seconds = elapsed {
            activeElapsedPhrase = Self.mmss(seconds)
        } else {
            activeElapsedPhrase = "00:00"
        }
    }

    var hourBuckets: [HourBucket] {
        let now = Date()
        let startOfHour = calendar.dateInterval(of: .hour, for: now)?.start
            ?? Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)

        // 24 hours descending from current hour start
        let startsDescending: [Date] = (0..<24).compactMap {
            calendar.date(byAdding: .hour, value: -$0, to: startOfHour)
        }

        let grouped = Dictionary(grouping: events) { evt in
            calendar.dateInterval(of: .hour, for: evt.removedAt)?.start
                ?? Date(timeIntervalSince1970: floor(evt.removedAt.timeIntervalSince1970 / 3600) * 3600)
        }

        return startsDescending.map { s in
            let eventsForHour = grouped[s] ?? []
            let sorted = eventsForHour.sorted { $0.removedAt < $1.removedAt }
            return HourBucket(hourStart: s, events: sorted)
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // Optimized: Only update every 2 minutes instead of every minute for power savings
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recomputeTimeSinceLast()
                // Keep the "currently in" label fresh - but less frequently
                if let ctx = Self.contextProvider?() {
                    let (active, elapsed) = self.fetchHasActivePouch(context: ctx)
                    self.hasActivePouch = active
                    if let seconds = elapsed {
                        self.activeElapsedPhrase = Self.mmss(seconds)
                    } else {
                        self.activeElapsedPhrase = "00:00"
                    }
                }
            }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func recomputeTimeSinceLast() {
        guard let lastRemoved = events
            .filter({ $0.removedAt < Date() })
            .max(by: { $0.removedAt < $1.removedAt })?.removedAt else {
            sinceLastHH = 0
            sinceLastMM = 0
            sinceLastPhrase = "0 hours 00 mins"
            return
        }

        let mins = Int(ceil(Date().timeIntervalSince(lastRemoved) / 60.0))
        sinceLastHH = mins / 60
        sinceLastMM = mins % 60
        sinceLastPhrase = "\(sinceLastHH) hours \(String(format: "%02d", sinceLastMM)) mins"
    }

    private func fetchHasActivePouch(context: NSManagedObjectContext) -> (Bool, TimeInterval?) {
        let request = NSFetchRequest<PouchLog>(entityName: "PouchLog")
        request.predicate = NSPredicate(format: "removalTime == nil")
        request.fetchLimit = 1
        if let row = try? context.fetch(request).first, let started = row.insertionTime {
            return (true, Date().timeIntervalSince(started))
        }
        return (false, nil)
    }

    private static func mmss(_ interval: TimeInterval) -> String {
        let secs = Int(max(interval, 0))
        return String(format: "%02d:%02d", secs/60, secs%60)
    }
}

// MARK: - View
struct UsageGraphView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var vm = UsageGraphViewModel()

    @FetchRequest private var recentLogs: FetchedResults<PouchLog>

    var streakDays: Int
    @State private var refreshTrigger = false
    @State private var showingEditSheet = false
    @State private var selectedPouchForEdit: PouchLog?

    init(streakDays: Int = 0) {
        self.streakDays = streakDays
        let since = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
        _recentLogs = FetchRequest(
            entity: PouchLog.entity(),
            sortDescriptors: [NSSortDescriptor(key: "insertionTime", ascending: false)],
            predicate: NSPredicate(format: "(insertionTime >= %@) OR (removalTime >= %@)", since as NSDate, since as NSDate),
            animation: .default
        )
    }

    var body: some View {
        mainContentView
            .onAppear(perform: setupView)
            .onChange(of: Array(recentLogs)) { _, _ in
                applyFetchToVM()
            }
            .onChange(of: refreshTrigger) { _, _ in
                applyFetchToVM()
            }
            .onReceive(pouchRemovedPublisher) { _ in
                refreshTrigger.toggle()
            }
            .onReceive(pouchEditedPublisher) { _ in
                refreshTrigger.toggle()
            }
            .onReceive(pouchDeletedPublisher) { _ in
                refreshTrigger.toggle()
            }
            .sheet(isPresented: $showingEditSheet, content: editSheetContent)
            .onChange(of: showingEditSheet) { _, newValue in
                onSheetStateChange(newValue)
            }
    }
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            headerTopSection
            Divider()
            scrollableContent
        }
    }
    
    private var scrollableContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(vm.hourBuckets) { bucket in
                    HourRowView(bucket: bucket, onEditPouch: handlePouchEdit)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 16)
                }
            }
        }
    }
    
    private var pouchRemovedPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))
    }
    
    private var pouchEditedPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSNotification.Name("PouchEdited"))
    }
    
    private var pouchDeletedPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSNotification.Name("PouchDeleted"))
    }

    private func applyFetchToVM() {
        vm.setEvents(Array(recentLogs), context: viewContext)
    }
    
    private func setupView() {
        UsageGraphViewModel.contextProvider = { viewContext }
        viewContext.automaticallyMergesChangesFromParent = true
        applyFetchToVM()
    }
    
    private func handlePouchEdit(_ event: PouchEvent) {
        print("🔍 Looking for pouch with ID: \(event.id)")
        print("🔍 Available pouches: \(recentLogs.map { $0.pouchId?.uuidString ?? "nil" })")
        
        if let pouchLog = findPouchLog(for: event) {
            print("✅ Found matching pouch log!")
            selectedPouchForEdit = pouchLog
            showingEditSheet = true
        } else {
            print("❌ No matching pouch found for event ID: \(event.id)")
        }
    }
    
    @ViewBuilder
    private func editSheetContent() -> some View {
        if let pouchLog = selectedPouchForEdit {
            let _ = print("📋 Presenting edit sheet for pouch: \(pouchLog.pouchId?.uuidString ?? "unknown")")
            PouchEditView(
                pouchLog: pouchLog,
                onSave: {
                    print("💾 Edit saved")
                    refreshTrigger.toggle()
                },
                onDelete: {
                    print("🗑️ Edit deleted")
                    refreshTrigger.toggle()
                }
            )
        } else {
            let _ = print("❌ No pouch selected for editing")
            Text("Error: No pouch selected")
                .presentationDetents([.medium])
        }
    }
    
    private func onSheetStateChange(_ newValue: Bool) {
        print("🔄 Sheet state changed to: \(newValue)")
        print("🔄 Selected pouch: \(selectedPouchForEdit?.pouchId?.uuidString ?? "nil")")
    }
    
    private func findPouchLog(for event: PouchEvent) -> PouchLog? {
        print("🔎 FindPouchLog - Looking for: \(event.id)")
        print("🔎 FindPouchLog - Event nicotine: \(event.nicotineMg)mg")
        print("🔎 FindPouchLog - Event time: \(event.removedAt)")
        
        // First try exact UUID match
        if let foundPouch = recentLogs.first(where: { $0.pouchId == event.id }) {
            print("✅ FindPouchLog - Exact UUID match found")
            return foundPouch
        }
        
        // Enhanced fallback strategy for pouches with nil IDs or timing issues
        let sortedPouches = recentLogs.sorted { pouch1, pouch2 in
            guard let time1 = pouch1.insertionTime ?? pouch1.removalTime,
                  let time2 = pouch2.insertionTime ?? pouch2.removalTime else {
                return false
            }
            return abs(event.removedAt.timeIntervalSince(time1)) < abs(event.removedAt.timeIntervalSince(time2))
        }
        
        for (index, pouchLog) in sortedPouches.enumerated() {
            guard let insertionTime = pouchLog.insertionTime else { continue }
            
            let timeDifferenceFromInsertion = abs(event.removedAt.timeIntervalSince(insertionTime))
            let nicotineMatch = abs(pouchLog.nicotineAmount - event.nicotineMg) < 0.1
            
            // Check against removal time if it exists
            let timeDifferenceFromRemoval: Double
            if let removalTime = pouchLog.removalTime {
                timeDifferenceFromRemoval = abs(event.removedAt.timeIntervalSince(removalTime))
            } else {
                timeDifferenceFromRemoval = Double.infinity
            }
            
            let minTimeDifference = min(timeDifferenceFromInsertion, timeDifferenceFromRemoval)
            
            print("🔎 Pouch #\(index): Nicotine \(pouchLog.nicotineAmount)mg, ID: \(pouchLog.pouchId?.uuidString ?? "nil")")
            print("🔎   Time diff (insertion): \(timeDifferenceFromInsertion)s")
            print("🔎   Time diff (removal): \(timeDifferenceFromRemoval == Double.infinity ? "N/A" : "\(timeDifferenceFromRemoval)s")")
            print("🔎   Nicotine match: \(nicotineMatch)")
            
            // More lenient matching: within 2 hours and exact nicotine match
            if nicotineMatch && minTimeDifference < 7200 { // 2 hours = 7200 seconds
                print("✅ FindPouchLog - Fallback match found (Pouch #\(index))")
                return pouchLog
            }
        }
        
        // Last resort: just match by nicotine amount (for debugging)
        if let lastResortPouch = recentLogs.first(where: { abs($0.nicotineAmount - event.nicotineMg) < 0.1 }) {
            print("🆘 FindPouchLog - Last resort match by nicotine amount only")
            return lastResortPouch
        }
        
        print("❌ FindPouchLog - No match found")
        print("🔎 Available pouches count: \(recentLogs.count)")
        
        return nil
    }

    private var headerTopSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("24‑Hour Streak")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(vm.streakDays) pouches")
                    .font(.title3).bold()
                    .foregroundColor(.orange)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(vm.hasActivePouch ? "Pouch is currently in" : "Since last pouch")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(vm.hasActivePouch ? vm.activeElapsedPhrase : vm.sinceLastPhrase)
                    .font(.title3).bold()
                    .monospacedDigit()
                    .foregroundColor(vm.hasActivePouch ? .blue : .green)
                    .accessibilityLabel(vm.hasActivePouch
                                        ? "\(vm.activeElapsedPhrase) elapsed"
                                        : "\(vm.sinceLastHH) hours \(vm.sinceLastMM) minutes")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Hour row
private struct HourRowView: View {
    let bucket: HourBucket
    let onEditPouch: (PouchEvent) -> Void

    private static let hourLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ha"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.hourLabel.string(from: bucket.hourStart))
                .font(.headline)
                .frame(width: 54, alignment: .leading)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(hourTitle)
                    .font(.subheadline)
                    .foregroundColor(.primary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if bucket.events.isEmpty {
                            EmptyHourPill()
                        } else {
                            ForEach(bucket.events) { event in
                                PouchCard(event: event, onEdit: {
                                    onEditPouch(event)
                                })
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hourTitle: String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        let endDate = Calendar.current.date(byAdding: .minute, value: 59, to: bucket.hourStart)
        let endString = df.string(from: endDate ?? bucket.hourStart)
        return "\(df.string(from: bucket.hourStart)) – \(endString)"
    }
}

// MARK: - Pouch card
private struct PouchCard: View {
    let event: PouchEvent
    let onEdit: () -> Void
    
    @State private var isPressed = false
    @State private var longPressTimer: Timer?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // For the Usage view (completed items), clamp to max absorbed per your linear model.
    private func absorbedAtEvent() -> Double {
        let maxAbsorbed = event.nicotineMg * ABSORPTION_FRACTION
        return maxAbsorbed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row
            HStack(spacing: 8) {
                Label {
                    Text(event.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                } icon: {
                    Image(systemName: "pills.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white)
                        .padding(6)
                        .background(Circle().fill(Color.blue))
                }
                .labelStyle(.titleAndIcon)
            }

            let timeString = Self.timeFormatter.string(from: event.removedAt)
            let absorbed = absorbedAtEvent()
            HStack {
                Text("\(timeString) • \(String(format: "%.3f", absorbed)) mg")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .scaleEffect(isPressed ? 1.2 : 1.0)
                    .rotationEffect(.degrees(90))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
                .scaleEffect(isPressed ? 0.95 : 1.0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double tap to edit (temporary for debugging)
            print("🎯 Double tap triggered for pouch: \(event.name)")
            onEdit()
            
            // Haptic feedback
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isPressed = true
                        }
                        
                        // Start long press timer
                        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
                            // Trigger long press action
                            print("🎯 Long press triggered for pouch: \(event.name)")
                            onEdit()
                            
                            // Haptic feedback
                            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                            impactFeedback.impactOccurred()
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isPressed = false
                    }
                    
                    // Cancel long press timer if it's still running
                    longPressTimer?.invalidate()
                    longPressTimer = nil
                }
        )
        .onDisappear {
            // Clean up timer when view disappears
            longPressTimer?.invalidate()
            longPressTimer = nil
        }
    }
}

private struct EmptyHourPill: View {
    var body: some View {
        Text("No pouches")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemFill))
            )
    }
}
