#if canImport(SwiftUI)
import SwiftUI

/// Colours for the ready-made approve screen.
public struct ApproveColors {
    public var accent: Color
    public var onAccent: Color
    public var background: Color
    public var text: Color
    public var muted: Color
    public init(accent: Color = Color(red: 0.12, green: 0.44, blue: 0.92), onAccent: Color = .white, background: Color = Color(white: 1),
                text: Color = Color(white: 0.07), muted: Color = Color(white: 0.38)) {
        self.accent = accent; self.onAccent = onAccent; self.background = background; self.text = text; self.muted = muted
    }
}

/// The ready-made approve screen: what is being approved, where from, three numbers and "No, it was not me".
/// Show it as a sheet when an approve push arrives or the app opens:
///
///     .sheet(isPresented: $asking) { ApproveView(signops: signops, requestId: id) { status in asking = false } }
///
/// onDone gets approved, denied, expired or none (nothing was waiting).
@available(iOS 16.0, macOS 13.0, *)
public struct ApproveView: View {
    let signops: SignOps
    let requestId: String?
    let colors: ApproveColors
    let onDone: (String) -> Void

    @State private var request: Approve.Request?
    @State private var note = "Checking for requests"
    @State private var busy = false
    @State private var secondsLeft = 120
    @State private var finished = false

    public init(signops: SignOps, requestId: String? = nil, colors: ApproveColors = ApproveColors(), onDone: @escaping (String) -> Void = { _ in }) {
        self.signops = signops; self.requestId = requestId; self.colors = colors; self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let r = request, !finished {
                Text(r.payment == nil ? "Is this you?" : "Approve this payment?").font(.system(size: 28, weight: .bold)).foregroundColor(colors.text)
                if let pay = r.payment {
                    Text(pay.amountText).font(.system(size: 36, weight: .bold)).foregroundColor(colors.text).padding(.top, 16)
                    Text("to \(pay.payee)").font(.system(size: 20)).foregroundColor(colors.text).padding(.top, 4)
                } else {
                    Text(r.context).font(.system(size: 20)).foregroundColor(colors.text).padding(.top, 16)
                }
                let place = [r.browser, r.city].compactMap { $0 }.joined(separator: ", ")
                if !place.isEmpty { Text(place).font(.system(size: 16)).foregroundColor(colors.muted).padding(.top, 6) }
                Text("Expires in \(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60))").font(.system(size: 14)).foregroundColor(colors.muted).padding(.top, 6)
                Text("Tap the number shown on the other screen").font(.system(size: 16)).foregroundColor(colors.text).padding(.top, 40)
                HStack(spacing: 12) {
                    ForEach(r.options, id: \.self) { n in
                        Button { pick(r, n) } label: {
                            Text(n).font(.system(size: 30, weight: .bold)).frame(maxWidth: .infinity, minHeight: 76)
                                .foregroundColor(colors.onAccent).background(colors.accent).clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .accessibilityLabel("Number \(n)")
                    }
                }
                .padding(.top, 14)
                Button { deny(r) } label: {
                    Text("No, it was not me").font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 56).foregroundColor(colors.text)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(colors.muted, lineWidth: 1))
                }
                .padding(.top, 28)
            } else {
                Text(note).font(.system(size: 18)).foregroundColor(colors.muted)
            }
            Spacer()
        }
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
        .padding(.horizontal, 24).padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.background.ignoresSafeArea())
        .task { await load() }
        .task(id: request?.id) { await countdown() }
    }

    private func load() async {
        do {
            let list = try await signops.approve.pending()
            if let r = list.first(where: { $0.id == requestId }) ?? list.first { request = r }
            else { await done("none", requestId != nil ? "This request was already answered or has expired." : "Nothing is waiting for you.") }
        } catch {
            await done("none", (error as? SignOpsError)?.message ?? error.localizedDescription)
        }
    }

    private func countdown() async {
        guard let r = request else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ends = f.date(from: r.expiresAt) ?? Date().addingTimeInterval(120)
        while !finished {
            secondsLeft = max(0, Int(ends.timeIntervalSinceNow))
            if secondsLeft == 0 { await done("expired", "This request expired."); return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func pick(_ r: Approve.Request, _ n: String) {
        busy = true
        Task {
            do {
                let a = try await signops.approve.approve(r, picked: n)
                await done(a.status, a.status == "approved" ? "Approved" : "Denied: that number was not the one on the other screen.")
            } catch let e as SignOpsError where e.code == "cancelled" {
                busy = false
            } catch {
                await done(((error as? SignOpsError)?.code == "expired") ? "expired" : "none", (error as? SignOpsError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func deny(_ r: Approve.Request) {
        busy = true
        Task {
            do { _ = try await signops.approve.deny(r); await done("denied", "Denied. Change your password if you did not try to sign in.") }
            catch { await done("none", (error as? SignOpsError)?.message ?? error.localizedDescription) }
        }
    }

    @MainActor private func done(_ status: String, _ text: String) async {
        finished = true
        busy = false
        note = text
        try? await Task.sleep(nanoseconds: status == "approved" ? 900_000_000 : 2_200_000_000)
        onDone(status)
    }
}
#endif
