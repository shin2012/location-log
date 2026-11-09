import SwiftUI
import MapKit
import CoreLocation
#if canImport(NMapsMap)
import NMapsMap
#endif
#if canImport(GoogleMaps)
import GoogleMaps
#endif

// MARK: - 지도 고르기 (네이버 기본 · 국외/오류면 구글 · 애플)

enum MapProvider: String, CaseIterable, Identifiable {
    case naver, google, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .naver: return "네이버"
        case .google: return "구글"
        case .apple: return "애플"
        }
    }
}

/// 지도 SDK 준비 상태 (키·인증)
final class MapServices: NSObject, ObservableObject {
    static let shared = MapServices()
    @Published private(set) var naverFailed = false
    @Published private(set) var naverError: String?

    private static func plist(_ k: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: k) as? String,
              !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }

    var hasNaver: Bool {
        #if canImport(NMapsMap)
        return Self.plist("NMFNcpKeyId") != nil
        #else
        return false
        #endif
    }

    var hasGoogle: Bool {
        #if canImport(GoogleMaps)
        return Self.plist("GMSApiKey") != nil
        #else
        return false
        #endif
    }

    /// 앱 시작 때 한 번
    func boot() {
        #if canImport(GoogleMaps)
        if let k = Self.plist("GMSApiKey") { GMSServices.provideAPIKey(k) }
        #endif
        #if canImport(NMapsMap)
        if Self.plist("NMFNcpKeyId") != nil { NMFAuthManager.shared().delegate = self }
        #endif
    }

    /// 실제로 쓸 지도: 고른 것 → (네이버가 인증 실패·국외면) 구글 → (키 없으면) 애플
    func resolve(_ want: MapProvider, near c: CLLocationCoordinate2D?) -> MapProvider {
        var p = want
        if p == .naver && (!hasNaver || naverFailed || (c.map { !Self.inKorea($0) } ?? false)) { p = .google }
        if p == .google && !hasGoogle { p = .apple }
        return p
    }

    /// 한국 (대마도·규슈 제외) — 웹판 inKR 과 같은 상자
    static func inKorea(_ c: CLLocationCoordinate2D) -> Bool {
        guard c.latitude > 33.0, c.latitude < 38.9, c.longitude > 124.5, c.longitude < 131.0 else { return false }
        if c.longitude > 129.1 && c.latitude < 35.0 { return false }      // 대마도·규슈 북쪽
        return true
    }
}

#if canImport(NMapsMap)
extension MapServices: NMFAuthManagerDelegate {
    func authorized(_ state: NMFAuthState, error: Error?) {
        DispatchQueue.main.async {
            if state == .unauthorized {
                self.naverFailed = true
                self.naverError = error?.localizedDescription ?? "인증 실패"
            } else if state == .authorized {
                self.naverFailed = false
                self.naverError = nil
            }
        }
    }
}
#endif

// MARK: - 지도에 그릴 것

struct MapLine: Identifiable {
    var id = UUID()
    var coords: [CLLocationCoordinate2D]
    var color: Color
    var width: CGFloat = 4
    var dashed = false
}

struct MapPin: Identifiable {
    var id: String
    var coord: CLLocationCoordinate2D
    var title: String
    var color: Color = .red
    var symbol: String = "mappin"
}

struct MapCircleArea: Identifiable {
    var id = UUID()
    var center: CLLocationCoordinate2D
    var radius: Double
    var color: Color = .blue
}

/// 화면 맞춤 요청: key 가 바뀔 때만 카메라를 옮김
struct MapFit: Equatable {
    var key: String
    var coords: [CLLocationCoordinate2D]
    static func == (a: MapFit, b: MapFit) -> Bool { a.key == b.key }
}

// MARK: - 공용 지도

/// 설정에서 고른 지도(네이버/구글/애플)로 선·핀·원을 그림.
/// follow: 내 위치 따라가기 (사용자가 지도를 끌면 false 로 바뀜). user: 따라갈 내 위치.
struct AppMap: View {
    var lines: [MapLine] = []
    var pins: [MapPin] = []
    var circles: [MapCircleArea] = []
    var fit: MapFit?
    var showsUser = false
    var follow: Binding<Bool>?
    var user: CLLocationCoordinate2D?
    var onTapPin: ((String) -> Void)?

    @AppStorage("mapProvider") private var want: MapProvider = .naver
    @ObservedObject private var services = MapServices.shared
    @Environment(\.colorScheme) private var scheme

    private var anchor: CLLocationCoordinate2D? {
        fit?.coords.first ?? lines.first?.coords.first ?? pins.first?.coord ?? circles.first?.center ?? user
    }

    var body: some View {
        switch services.resolve(want, near: anchor) {
        #if canImport(NMapsMap)
        case .naver:
            NaverMapRep(dark: scheme == .dark, lines: lines, pins: pins, circles: circles, fit: fit, showsUser: showsUser,
                        follow: follow, onTapPin: onTapPin)
        #endif
        #if canImport(GoogleMaps)
        case .google:
            GoogleMapRep(dark: scheme == .dark, lines: lines, pins: pins, circles: circles, fit: fit, showsUser: showsUser,
                         follow: follow, user: user, onTapPin: onTapPin)
        #endif
        default:
            AppleMapRep(lines: lines, pins: pins, circles: circles, fit: fit, showsUser: showsUser,
                        follow: follow, onTapPin: onTapPin)
        }
    }

    static func region(_ cs: [CLLocationCoordinate2D]) -> (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D)? {
        guard let f = cs.first else { return nil }
        var s = f.latitude, n = f.latitude, w = f.longitude, e = f.longitude
        for c in cs { s = min(s, c.latitude); n = max(n, c.latitude); w = min(w, c.longitude); e = max(e, c.longitude) }
        // 한 점이면 300m 쯤 보이게
        let pad = max(n - s, (e - w)) < 0.002 ? 0.0015 : 0
        return (.init(latitude: s - pad, longitude: w - pad), .init(latitude: n + pad, longitude: e + pad))
    }
}

// MARK: 애플

private struct AppleMapRep: View {
    let lines: [MapLine]
    let pins: [MapPin]
    let circles: [MapCircleArea]
    let fit: MapFit?
    let showsUser: Bool
    let follow: Binding<Bool>?
    let onTapPin: ((String) -> Void)?
    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: String?

    var body: some View {
        Map(position: $camera, selection: $selection) {
            if showsUser { UserAnnotation() }
            ForEach(lines) { l in
                MapPolyline(coordinates: l.coords)
                    .stroke(l.color, style: StrokeStyle(lineWidth: l.width, lineCap: .round, lineJoin: .round,
                                                        dash: l.dashed ? [6, 8] : []))
            }
            ForEach(circles) { c in
                MapCircle(center: c.center, radius: c.radius)
                    .foregroundStyle(c.color.opacity(0.2))
                    .stroke(c.color, lineWidth: 2)
            }
            ForEach(pins) { p in
                Marker(p.title, systemImage: p.symbol, coordinate: p.coord).tint(p.color).tag(p.id)
            }
        }
        .mapControls { MapScaleView(); MapCompass() }
        .onChange(of: selection) { _, s in if let s { onTapPin?(s); selection = nil } }
        .onAppear { apply(fit); if follow?.wrappedValue == true { camera = .userLocation(fallback: .automatic) } }
        .onChange(of: fit) { _, f in apply(f) }
        .onChange(of: follow?.wrappedValue) { _, v in if v == true { withAnimation { camera = .userLocation(fallback: .automatic) } } }
        .onMapCameraChange { _ in
            if follow?.wrappedValue == true && !camera.followsUserLocation { follow?.wrappedValue = false }
        }
    }

    private func apply(_ f: MapFit?) {
        guard follow?.wrappedValue != true, let f, let r = AppMap.region(f.coords) else { return }
        let a = MKMapPoint(r.sw), b = MKMapPoint(r.ne)
        var rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let pad = max(rect.width, rect.height) * 0.15
        rect = rect.insetBy(dx: -pad, dy: -pad)
        withAnimation { camera = .rect(rect) }
    }
}

// MARK: 네이버

#if canImport(NMapsMap)
private struct NaverMapRep: UIViewRepresentable {
    let dark: Bool
    let lines: [MapLine]
    let pins: [MapPin]
    let circles: [MapCircleArea]
    let fit: MapFit?
    let showsUser: Bool
    let follow: Binding<Bool>?
    let onTapPin: ((String) -> Void)?

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> NMFMapView {
        let v = NMFMapView(frame: .zero)
        v.addCameraDelegate(delegate: context.coordinator)
        v.logoAlign = .leftBottom
        return v
    }

    func updateUIView(_ v: NMFMapView, context: Context) {
        let c = context.coordinator
        c.follow = follow
        // 다크 모드: 네이버는 야간 모드가 내비 지도에서만 됨 → 다크일 때 내비 + 야간
        if c.dark != dark {
            c.dark = dark
            v.mapType = dark ? .navi : .basic
            v.isNightModeEnabled = dark
            v.backgroundColor = dark ? .black : .white
        }
        c.overlays.forEach { $0.mapView = nil }
        c.overlays = []
        for l in lines where l.coords.count > 1 {
            let o: NMFPolylineOverlay? = NMFPolylineOverlay(l.coords.map { NMGLatLng(lat: $0.latitude, lng: $0.longitude) })
            guard let o else { continue }
            o.width = l.width
            o.color = UIColor(l.color)
            o.capType = .round
            o.joinType = .round
            if l.dashed { o.pattern = [8, 8] }
            o.mapView = v
            c.overlays.append(o)
        }
        for a in circles {
            let o: NMFCircleOverlay? = NMFCircleOverlay(NMGLatLng(lat: a.center.latitude, lng: a.center.longitude), radius: a.radius)
            guard let o else { continue }
            o.fillColor = UIColor(a.color).withAlphaComponent(0.2)
            o.outlineColor = UIColor(a.color)
            o.outlineWidth = 2
            o.mapView = v
            c.overlays.append(o)
        }
        for p in pins {
            let m = NMFMarker(position: NMGLatLng(lat: p.coord.latitude, lng: p.coord.longitude))
            let img = PinImage.make(color: UIColor(p.color), symbol: p.symbol)
            m.iconImage = NMFOverlayImage(image: img)
            m.width = img.size.width
            m.height = img.size.height
            m.anchor = CGPoint(x: 0.5, y: 1)
            m.captionText = p.title
            m.captionTextSize = 12
            m.captionColor = dark ? .white : .black
            m.captionHaloColor = dark ? .black : .white
            m.isHideCollidedCaptions = true
            let id = p.id, tap = onTapPin
            m.touchHandler = { _ in tap?(id); return true }
            m.mapView = v
            c.overlays.append(m)
        }
        let followOn = follow?.wrappedValue == true
        if showsUser || followOn {
            if followOn { if v.positionMode != .direction { v.positionMode = .direction } }
            else if v.positionMode == .disabled || v.positionMode == .direction { v.positionMode = .normal }
        } else {
            v.positionMode = .disabled
        }
        if !followOn, let f = fit, f.key != c.fitKey {
            c.fit(v, f)
        }
    }

    final class Coord: NSObject, NMFMapViewCameraDelegate {
        var overlays: [NMFOverlay] = []
        var dark: Bool?
        var fitKey: String?
        var follow: Binding<Bool>?

        /// 화면 맞춤. 처음 updateUIView 때는 지도 뷰 크기가 0이라 fit(bounds) 가 먹지 않고
        /// 카메라가 SDK 기본 위치(네이버 본사·분당)에 남음 → 가운데만 먼저 옮기고, 크기가 잡히면 다시 맞춤.
        func fit(_ v: NMFMapView, _ f: MapFit, tries: Int = 0) {
            guard let r = AppMap.region(f.coords) else { return }
            fitKey = f.key
            let b = NMGLatLngBounds(southWest: NMGLatLng(lat: r.sw.latitude, lng: r.sw.longitude),
                                    northEast: NMGLatLng(lat: r.ne.latitude, lng: r.ne.longitude))
            if v.bounds.width < 10 || v.bounds.height < 10 {
                if tries == 0 {
                    v.moveCamera(NMFCameraUpdate(scrollTo: NMGLatLng(lat: (r.sw.latitude + r.ne.latitude) / 2,
                                                                     lng: (r.sw.longitude + r.ne.longitude) / 2), zoomTo: 15))
                }
                guard tries < 60 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak v] in
                    guard let self, let v, self.fitKey == f.key, self.follow?.wrappedValue != true else { return }
                    self.fit(v, f, tries: tries + 1)
                }
                return
            }
            let u = NMFCameraUpdate(fit: b, padding: 40)
            u.animation = tries == 0 ? .easeIn : .none
            v.moveCamera(u)
        }

        func mapView(_ mapView: NMFMapView, cameraWillChangeByReason reason: Int, animated: Bool) {
            if reason == NMFMapChangedByGesture, follow?.wrappedValue == true {
                DispatchQueue.main.async { self.follow?.wrappedValue = false }
            }
        }
    }
}
#endif

// MARK: 구글

#if canImport(GoogleMaps)
private struct GoogleMapRep: UIViewRepresentable {
    let dark: Bool
    let lines: [MapLine]
    let pins: [MapPin]
    let circles: [MapCircleArea]
    let fit: MapFit?
    let showsUser: Bool
    let follow: Binding<Bool>?
    let user: CLLocationCoordinate2D?
    let onTapPin: ((String) -> Void)?

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> GMSMapView {
        let v = GMSMapView(frame: .zero)
        v.delegate = context.coordinator
        v.settings.compassButton = true
        return v
    }

    func updateUIView(_ v: GMSMapView, context: Context) {
        let c = context.coordinator
        c.follow = follow
        c.onTapPin = onTapPin
        v.overrideUserInterfaceStyle = dark ? .dark : .light
        v.clear()
        for l in lines where l.coords.count > 1 {
            let path = GMSMutablePath()
            l.coords.forEach { path.add($0) }
            let o = GMSPolyline(path: path)
            o.strokeWidth = l.width
            o.strokeColor = UIColor(l.color)
            if l.dashed {
                o.spans = GMSStyleSpans(path, [GMSStrokeStyle.solidColor(UIColor(l.color)), GMSStrokeStyle.solidColor(.clear)],
                                        [12, 10], .rhumb)
            }
            o.map = v
        }
        for a in circles {
            let o = GMSCircle(position: a.center, radius: a.radius)
            o.fillColor = UIColor(a.color).withAlphaComponent(0.2)
            o.strokeColor = UIColor(a.color)
            o.strokeWidth = 2
            o.map = v
        }
        for p in pins {
            let m = GMSMarker(position: p.coord)
            m.title = p.title
            m.icon = PinImage.make(color: UIColor(p.color), symbol: p.symbol)
            m.groundAnchor = CGPoint(x: 0.5, y: 1)
            m.userData = p.id
            m.map = v
        }
        let followOn = follow?.wrappedValue == true
        v.isMyLocationEnabled = showsUser || followOn
        if followOn, let u = user {
            v.animate(toLocation: u)
            if v.camera.zoom < 14 { v.animate(toZoom: 16) }
        } else if let f = fit, f.key != c.fitKey {
            c.fit(v, f)
        }
    }

    final class Coord: NSObject, GMSMapViewDelegate {
        var fitKey: String?
        var follow: Binding<Bool>?
        var onTapPin: ((String) -> Void)?

        /// 화면 맞춤 (크기 0일 때는 가운데만 옮기고, 크기가 잡히면 다시 맞춤 — 네이버와 같은 이유)
        func fit(_ v: GMSMapView, _ f: MapFit, tries: Int = 0) {
            guard let r = AppMap.region(f.coords) else { return }
            fitKey = f.key
            if v.bounds.width < 10 || v.bounds.height < 10 {
                if tries == 0 {
                    v.moveCamera(GMSCameraUpdate.setTarget(CLLocationCoordinate2D(latitude: (r.sw.latitude + r.ne.latitude) / 2,
                                                                                   longitude: (r.sw.longitude + r.ne.longitude) / 2), zoom: 15))
                }
                guard tries < 60 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak v] in
                    guard let self, let v, self.fitKey == f.key, self.follow?.wrappedValue != true else { return }
                    self.fit(v, f, tries: tries + 1)
                }
                return
            }
            let u = GMSCameraUpdate.fit(GMSCoordinateBounds(coordinate: r.sw, coordinate: r.ne), withPadding: 40)
            if tries == 0 { v.animate(with: u) } else { v.moveCamera(u) }
        }

        func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
            if gesture, follow?.wrappedValue == true {
                DispatchQueue.main.async { self.follow?.wrappedValue = false }
            }
        }

        func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
            if let id = marker.userData as? String, let f = onTapPin { f(id); return true }
            return false
        }
    }
}
#endif


// MARK: - 핀 그림 (네이버·구글 공용, 애플 Marker 와 비슷한 모양: 색 원 + 흰 기호 + 아래 꼭지)

enum PinImage {
    private static var cache: [String: UIImage] = [:]

    static func make(color: UIColor, symbol: String, size: CGFloat = 30) -> UIImage {
        let key = "\(symbol)|\(color.description)|\(size)"
        if let i = cache[key] { return i }
        let tail: CGFloat = 7, pad: CGFloat = 3
        let canvas = CGSize(width: size + pad * 2, height: size + tail + pad * 2)
        let img = UIGraphicsImageRenderer(size: canvas).image { ctx in
            let g = ctx.cgContext
            let circle = CGRect(x: pad, y: pad, width: size, height: size)
            g.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            // 꼭지
            let path = UIBezierPath()
            path.move(to: CGPoint(x: canvas.width / 2 - 6, y: circle.maxY - 4))
            path.addLine(to: CGPoint(x: canvas.width / 2, y: circle.maxY + tail))
            path.addLine(to: CGPoint(x: canvas.width / 2 + 6, y: circle.maxY - 4))
            path.close()
            color.setFill(); path.fill()
            // 원 + 흰 테두리
            let ring = UIBezierPath(ovalIn: circle)
            color.setFill(); ring.fill()
            g.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.white.setStroke(); ring.lineWidth = 2; ring.stroke()
            // 기호
            let cfg = UIImage.SymbolConfiguration(pointSize: size * 0.45, weight: .semibold)
            if let sym = UIImage(systemName: symbol, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                sym.draw(in: CGRect(x: circle.midX - sym.size.width / 2, y: circle.midY - sym.size.height / 2,
                                    width: sym.size.width, height: sym.size.height))
            }
        }
        cache[key] = img
        return img
    }
}
