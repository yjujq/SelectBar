import AppKit
import ObjectiveC.runtime

/// Панель, которая никогда не забирает фокус.
///
/// Это ключевое требование: если окно станет ключевым, приложение под ним
/// снимет выделение, и мы покажем кнопки для текста, которого уже нет.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Подложка панели, которая сама заявляет курсор-стрелку.
///
/// Без этого над панелью остаётся курсор от окна снизу — обычно курсив
/// текстового поля, из которого шло выделение. Он сбивает с толку: по виду
/// указатель стоит над текстом, хотя на деле над кнопкой.
private final class ArrowCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

@MainActor
final class PopupController {
    private var panel: NonActivatingPanel?
    private var currentText = ""
    private var currentActions: [Action] = []
    private var dismissMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(actions: [Action], text: String, rect: NSRect?, near fallbackPoint: NSPoint) {
        hide()
        guard !actions.isEmpty else { return }
        currentText = text
        currentActions = actions

        let content = buildBar(actions: actions)
        let size = content.fittingSize

        let origin = position(size: size, cursor: fallbackPoint)
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Уровень 3: выше обычных окон приложений (0), но ниже Dock (20),
        // строки меню (24), Пункта управления (25) и контекстных меню (~101).
        // На popUpMenu панель перекрывала всё это, включая подсказки.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень нужна только сплошной заливке. У стекла она своя, и вторая
        // ложится поверх двойным контуром; у размытия тень окна обводит
        // капсулу заметным кантом — сама подложка ничего не рисует,
        // во всём её дереве слоёв borderWidth = 0.
        panel.hasShadow = ActionStore.shared.barStyle == .solid
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = appearance(for: ActionStore.shared.barAppearance)
        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel

        // Закрываемся от любого клика или нажатия клавиши вне панели.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.hide() }
        }
    }

    func hide() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Построение панели

    private func buildBar(actions: [Action]) -> NSView {
        let store = ActionStore.shared
        let scale = store.barScale

        if #available(macOS 26.0, *),
           store.barStyle == .glass || store.barStyle == .glassClear {
            return buildGlassBar(actions: actions, store: store, scale: scale)
        }

        // Кнопки вплотную друг к другу и во всю высоту капсулы: между ними
        // не остаётся мёртвых полос, промахнуться мимо значка нельзя.
        // Размер капсулы прежний — прибавка к кнопке взята из отступов.
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2.5 * scale,
                                        bottom: 0, right: 2.5 * scale)
        for action in actions {
            stack.addArrangedSubview(makeButton(for: action,
                                                width: 31 * scale, height: 30 * scale))
        }

        let size = stack.fittingSize
        // Половина высоты даёт капсулу: края скруглены полностью, полукругом.
        // Считаем от фактического размера, чтобы форма сохранялась при любом
        // масштабе панели.
        let radius: CGFloat = size.height / 2

        let container = makeBackground(store: store, size: size, radius: radius, stack: stack)
        // Тему ставим на саму подложку, а не только на окно: иначе цвета иконок
        // берутся из системной темы и на своей заливке читаются неверно.
        container.appearance = appearance(for: store.barAppearance)
        return container
    }

    /// Стеклянная панель по приёмам Apple: несколько капсул в общем контейнере.
    ///
    /// Ключевое здесь — NSGlassEffectContainerView. Он не просто держит капсулы
    /// рядом: близко стоящие стеклянные формы он сращивает в одну текучую, а на
    /// расстоянии разводит. Именно так собраны панели инструментов в системных
    /// приложениях. Складывать стекло на стекло вручную нельзя — слои начинают
    /// преломлять друг друга, и вид разваливается.
    ///
    /// Кнопки намеренно лежат НЕ внутри стекла, а отдельным слоем поверх него.
    /// Внутри стекла нажатия до них не доходили. В отрыве от экрана разметка
    /// проверку проходит, значит перехватывает живой стеклянный слой, а его
    /// поведение нам неподвластно. Поэтому стекло оставлено чистой подложкой:
    /// нажатия идут по обычным представлениям и от него не зависят.
    @available(macOS 26.0, *)
    private func buildGlassBar(actions: [Action], store: ActionStore, scale: CGFloat) -> NSView {
        // Действия разложены по смысловым группам с сохранением порядка:
        // встроенные, ссылки, команды оболочки. Каждая группа — своя капсула.
        var order: [Int] = []
        var groups: [Int: [Action]] = [:]
        for action in actions {
            if groups[action.group] == nil { order.append(action.group) }
            groups[action.group, default: []].append(action)
        }

        // Поля Apple для панели значков: по бокам заметно больше, чем сверху.
        let insets = NSEdgeInsets(top: 0, left: 2.5 * scale,
                                  bottom: 0, right: 2.5 * scale)
        let gap: CGFloat = 8 * scale

        // Ряд кнопок — он же задаёт размеры, по которым строится стекло.
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = gap
        var groupSizes: [NSSize] = []
        for key in order {
            let inner = NSStackView()
            inner.orientation = .horizontal
            inner.spacing = 0
            inner.edgeInsets = insets
            for action in groups[key] ?? [] {
                inner.addArrangedSubview(makeButton(for: action,
                                                    width: 33 * scale, height: 32 * scale))
            }
            let groupSize = inner.fittingSize
            groupSizes.append(groupSize)

            // Почти прозрачная заливка по форме капсулы. Окно панели прозрачное,
            // и macOS пропускает нажатие в окно снизу там, где пиксель в буфере
            // окна пуст. Стекло рисуется отдельным слоем композитора и в буфер
            // ничего не пишет, поэтому без этой заливки непрозрачны только сами
            // штрихи значков: попал в штрих — сработало, попал в просвет — ушло
            // в текст под панелью. Отсюда и курсив вместо стрелки, и то, что
            // нажатие срабатывало через раз.
            //
            // Размытию это не нужно: NSVisualEffectView заливает площадь сам,
            // потому в Blur ничего подобного и не наблюдалось.
            inner.wantsLayer = true
            inner.layer?.backgroundColor = NSColor(white: 0, alpha: 0.02).cgColor
            inner.layer?.cornerRadius = groupSize.height / 2

            buttons.addArrangedSubview(inner)
        }
        let size = buttons.fittingSize

        // Стеклянная подложка тех же размеров, но пустая внутри.
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = gap
        for groupSize in groupSizes {
            let capsule = NSGlassEffectView()
            // .clear только поверх снимков и видео, для всего прочего .regular —
            // иначе значки теряют опору и перестают читаться на пёстром фоне.
            capsule.style = store.barStyle == .glassClear ? .clear : .regular
            capsule.tintColor = store.tintColor
            capsule.cornerRadius = groupSize.height / 2

            // Стекло само подстраивает тему под то, что под ним: на светлом фоне
            // светлеет, на тёмном темнеет. Нам нужна тема из настроек, а не из
            // обоев, поэтому подстройку выключаем.
            //
            // Свойство внутреннее: 0 — automatic, 1 — off, 2 — on (по умолчанию).
            // Значения выяснены перебором; 3 роняет AppKit, поэтому только 1.
            // Наличие проверяем: если в новой системе свойства не станет,
            // setValue бросил бы исключение Objective-C, которое Swift не ловит,
            // и панель падала бы при каждом показе. Так она просто останется
            // с подстройкой — хуже вид, но не работоспособность.
            if class_getProperty(NSGlassEffectView.self, "_adaptiveAppearance") != nil {
                capsule.setValue(1, forKey: "_adaptiveAppearance")
            }
            capsule.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                capsule.widthAnchor.constraint(equalToConstant: groupSize.width),
                capsule.heightAnchor.constraint(equalToConstant: groupSize.height),
            ])
            row.addArrangedSubview(capsule)
        }

        let container = NSGlassEffectContainerView()
        // Расстояние сращивания: капсулы ближе этого сливаются в одну форму.
        container.spacing = 10 * scale
        row.translatesAutoresizingMaskIntoConstraints = true
        row.frame = NSRect(origin: .zero, size: size)
        container.contentView = row
        container.frame = NSRect(origin: .zero, size: size)
        container.appearance = appearance(for: store.barAppearance)

        // Обёртка: стекло снизу, кнопки сверху. Обе точно совпадают по геометрии,
        // потому что построены из одних и тех же отступов и зазоров.
        // Поле по краям. Стекло рисует собственную тень и свечение ЗА границами
        // своего вида, а окно панели строится по размеру содержимого. Без поля
        // видимая капсула оказывается больше окна: ведёшь мышь к её краю и
        // выходишь из окна раньше, чем из картинки — курсор становится курсивом
        // от текста снизу, и нажатие уходит туда же, мимо кнопки.
        let margin: CGFloat = 0
        let outer = ArrowCursorView(frame: NSRect(x: 0, y: 0,
                                                  width: size.width + margin * 2,
                                                  height: size.height + margin * 2))
        container.translatesAutoresizingMaskIntoConstraints = true
        container.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        outer.addSubview(container)
        buttons.translatesAutoresizingMaskIntoConstraints = true
        buttons.frame = container.frame
        outer.addSubview(buttons)

        // Явные размеры: иначе fittingSize пустой обёртки равен нулю
        // и окно панели схлопнется.
        outer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outer.widthAnchor.constraint(equalToConstant: size.width + margin * 2),
            outer.heightAnchor.constraint(equalToConstant: size.height + margin * 2),
        ])
        outer.appearance = appearance(for: store.barAppearance)
        return outer
    }

    private func appearance(for setting: BarAppearance) -> NSAppearance? {
        switch setting {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Сплошной цвет подложки: тёмный или светлый, с наложенным оттенком.
    /// В отличие от стекла не зависит от того, что находится под панелью.
    private func solidColor(store: ActionStore) -> NSColor {
        let dark: Bool
        switch store.barAppearance {
        case .light: dark = false
        case .dark:  dark = true
        case .system:
            dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        var base = dark ? NSColor(white: 0.14, alpha: 0.97)
                        : NSColor(white: 0.97, alpha: 0.97)

        // Оттенок подмешиваем в основу, а не кладём сверху отдельным слоем.
        if let tint = store.tintColor?.usingColorSpace(.sRGB),
           let mixed = base.usingColorSpace(.sRGB) {
            let a = tint.alphaComponent
            base = NSColor(srgbRed: mixed.redComponent * (1 - a) + tint.redComponent * a,
                           green: mixed.greenComponent * (1 - a) + tint.greenComponent * a,
                           blue: mixed.blueComponent * (1 - a) + tint.blueComponent * a,
                           alpha: mixed.alphaComponent)
        }
        return base
    }

    private func makeBackground(store: ActionStore, size: NSSize,
                                radius: CGFloat, stack: NSStackView) -> NSView {
        func fill(_ view: NSView) -> NSView {
            view.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stack.topAnchor.constraint(equalTo: view.topAnchor),
                stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            view.frame = NSRect(origin: .zero, size: size)
            return view
        }

        if #available(macOS 26.0, *), store.barStyle == .glass || store.barStyle == .glassClear {
            let glass = NSGlassEffectView()
            glass.style = store.barStyle == .glassClear ? .clear : .regular
            glass.tintColor = store.tintColor
            glass.cornerRadius = radius

            stack.translatesAutoresizingMaskIntoConstraints = true
            stack.frame = NSRect(origin: .zero, size: size)
            glass.contentView = stack
            glass.frame = NSRect(origin: .zero, size: size)
            return glass
        }

        if store.barStyle == .blur {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.masksToBounds = true
            return fill(blur)
        }

        let plain = NSView()
        plain.wantsLayer = true
        plain.layer?.cornerRadius = radius
        plain.layer?.masksToBounds = true
        plain.layer?.backgroundColor = solidColor(store: store).cgColor
        return fill(plain)
    }

    /// Размеры задаются вызывающим: кнопка должна заполнять капсулу целиком,
    /// чтобы нажатие ловилось не только по значку. Значок внутри остаётся
    /// прежнего кегля и просто стоит по центру — на вид ничего не меняется.
    private func makeButton(for action: Action,
                            width: CGFloat, height: CGFloat) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(perform(_:)))

        // Часть символов появилась в свежих версиях SF Symbols — если имени нет,
        // берём запасное, чтобы кнопка не осталась пустой.
        let scale = ActionStore.shared.barScale
        let config = NSImage.SymbolConfiguration(pointSize: 14 * scale, weight: .regular)
        let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            ?? NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: action.title)
        if let image {
            button.image = image.withSymbolConfiguration(config)
            button.imagePosition = .imageOnly
        } else {
            button.title = action.title       // совсем без картинки — пусть будет подпись
        }

        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.setButtonType(.momentaryChange)
        button.toolTip = action.tooltip ?? action.title
        button.identifier = NSUserInterfaceItemIdentifier(action.title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: height),
        ])
        return button
    }

    @objc private func perform(_ sender: NSButton) {
        let title = sender.identifier?.rawValue ?? ""
        let text = currentText
        hide()
        currentActions.first { $0.title == title }?.run(text)
    }

    // MARK: - Размещение

    /// Панель ставится у курсора, а не над выделением: так она всегда
    /// оказывается там, где взгляд, и не прыгает по экрану вслед за длинным
    /// выделением, начало которого может быть далеко от места отпускания мыши.
    private func position(size: NSSize, cursor: NSPoint) -> NSPoint {
        let gap: CGFloat = 14
        var origin = NSPoint(x: cursor.x - size.width / 2, y: cursor.y + gap)

        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        // Сверху не помещается — показываем под курсором.
        if origin.y + size.height > visible.maxY {
            origin.y = cursor.y - size.height - gap
        }
        origin.y = max(origin.y, visible.minY + 4)
        return origin
    }
}
