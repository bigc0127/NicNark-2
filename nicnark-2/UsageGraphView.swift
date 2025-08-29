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
        VStack(spacing: 0) {
            headerTopSection
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.hourBuckets) { bucket in
                        HourRowView(
                            bucket: bucket,
                            onEditPouch: { event in
                                if let pouchLog = findPouchLog(for: event) {
                                    selectedPouchForEdit = pouchLog
                                    showingEditSheet = true
                                }
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .onAppear {
            UsageGraphViewModel.contextProvider = { viewContext }
            viewContext.automaticallyMergesChangesFromParent = true
            applyFetchToVM()
        }
        .onChange(of: Array(recentLogs)) { _, _ in
            applyFetchToVM()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))) { _ in
            refreshTrigger.toggle()
        }
        .onChange(of: refreshTrigger) { _, _ in
            applyFetchToVM()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchEdited"))) { _ in
            refreshTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchDeleted"))) { _ in
            refreshTrigger.toggle()
        }
        .sheet(isPresented: $showingEditSheet) {
            if let pouchLog = selectedPouchForEdit {
                PouchEditView(
                    pouchLog: pouchLog,
                    onSave: {
                        refreshTrigger.toggle()
                    },
                    onDelete: {
                        refreshTrigger.toggle()
                    }
                )
            }
        }
    }

    private func applyFetchToVM() {
        vm.setEvents(Array(recentLogs), context: viewContext)
    }
    
    private func findPouchLog(for event: PouchEvent) -> PouchLog? {
        return recentLogs.first { pouchLog in
            pouchLog.pouchId == event.id
        }
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
