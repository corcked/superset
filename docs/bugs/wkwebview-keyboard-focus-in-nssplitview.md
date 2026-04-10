# Bug: WKWebView не принимает keyboard input внутри NSSplitView

## Симптомы

- Терминал (xterm.js в WKWebView) рендерится корректно — показывает shell prompt, получает PTY output
- Мышкой можно выделять текст в терминале
- Клавиатурный ввод **не доходит** до xterm.js — нажатия клавиш игнорируются
- Клавиатурные шорткаты (⌘+1-9 и т.д.) тоже не работают

## Контекст

### Архитектура окна

```
NSWindow
└── NSSplitViewController
    ├── NSSplitViewItem (sidebar)
    │   └── NSHostingController (SwiftUI sidebar)
    └── NSSplitViewItem (content)
        └── NSViewController
            └── NSView (container)
                └── WKWebView
                    └── HTML: xterm.js Terminal
```

WKWebView хостит xterm.js терминал. До Phase 2a (когда WKWebView занимал всё окно напрямую без NSSplitView) клавиатурный ввод работал.

### Что изменилось

В Phase 2a WKWebView был перемещён из `window.contentView` напрямую в NSSplitViewController:
- WKWebView обёрнут в NSView (container) через Auto Layout constraints
- Container view принадлежит NSViewController
- NSViewController добавлен как contentListWithViewController в NSSplitViewItem

## Диагностика

### Что подтверждено

1. **NSEvent monitor перехватывает key events** — подтверждено NSLog. Клавиши доходят до `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`. Monitor корректно возвращает `event` (не nil) для обычных клавиш — он их не съедает.

2. **`makeFirstResponder(webView)` возвращает `true`** — AppKit считает что фокус передан. Но `window.firstResponder` показывает `Optional<NSResponder>` (не конкретный тип WKWebView или его subview).

3. **xterm.js `term.focus()` вызывается** — JS `showTerminal` вызывает `term.focus()` внутри `requestAnimationFrame`. evaluateJavaScript не возвращает ошибок.

4. **Русская раскладка не мешает** — `charactersIgnoringModifiers` корректно возвращает символы, KeyboardShortcutManager их пропускает (return event).

5. **PTY output работает** — данные от PTY доходят до xterm.js через evaluateJavaScript + base64, терминал рендерит shell prompt.

6. **Без NSSplitView работало** — в Phase 1, когда WKWebView был добавлен напрямую в `window.contentView`, клавиатурный ввод работал.

### Что неизвестно

- Является ли WKWebView или его внутренний subview (WKContentView) actual first responder
- Доходят ли key events до WKWebView после прохождения через NSEvent monitor
- Есть ли конфликт между NSSplitViewController responder chain и WKWebView

## Попытки решения

### Попытка 1: `window.makeFirstResponder(webView)`

**Что:** Вызов `window.makeFirstResponder(webView)` после `createAndShowTerminal`, `switchTerminal`, и `handleJSReady`.

**Результат:** `makeFirstResponder` возвращает `true`, но клавиатурный ввод не работает. WKWebView внутри NSSplitView видимо требует больше чем просто AppKit first responder — нужна активация внутреннего WebKit editing state.

**Файл:** `Sources/App/MainWindowController.swift`, строки 144, 163, 205

### Попытка 2: Отключение KeyboardShortcutManager

**Что:** Полностью закомментировал `keyboardManager.install()` чтобы исключить влияние NSEvent monitor.

**Результат:** Ввод всё равно не работает. NSEvent monitor не является причиной проблемы.

**Файл:** `Sources/App/MainWindowController.swift`, строка 42

### Попытка 3: Симуляция mouse click на WKWebView

**Что:** Программное создание `NSEvent.mouseEvent(with: .leftMouseDown/Up)` и вызов `webView.mouseDown(with:)` / `webView.mouseUp(with:)` для имитации клика, который должен активировать WebKit editing state.

```swift
func focusWebView() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self, let contentView = self.webView.superview else { return }
        let viewCenter = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let windowPoint = contentView.convert(viewCenter, to: nil)

        let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: self.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1.0
        )
        let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: windowPoint,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: self.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0.0
        )

        if let down = mouseDown { self.webView.mouseDown(with: down) }
        if let up = mouseUp { self.webView.mouseUp(with: up) }
        self.window.makeFirstResponder(self.webView)
    }
}
```

**Результат:** Не работает. Прямой вызов `mouseDown(with:)` на WKWebView может не проходить через полный event dispatch pipeline WebKit.

**Файл:** `Sources/App/MainWindowController.swift`, метод `focusWebView()`

### Попытка 4: `asyncAfter` задержка

**Что:** Добавлена задержка 0.1-0.3 секунды перед вызовом `makeFirstResponder` и `focusWebView`, чтобы дать WebView время завершить layout.

**Результат:** Не помогло.

## Возможные направления решения

### Направление A: Использовать `WKWebView` как view VC напрямую

Вместо обёртки в container NSView, сделать WKWebView прямым view NSViewController:

```swift
let rightVC = NSViewController()
rightVC.view = webView  // напрямую, без container
```

Это может сохранить responder chain. Проблема: может сломать Auto Layout в NSSplitView (была причина ввести container — container 0x0 bug).

### Направление B: `NSApplication.sendEvent` вместо `webView.mouseDown`

Отправить synthetic mouse event через `NSApp.sendEvent()` вместо прямого вызова на webView — это пройдёт через полный event dispatch:

```swift
if let down = mouseDown {
    NSApp.sendEvent(down)
}
```

### Направление C: `webView.performClick(nil)`

Попробовать стандартный NSView метод `performClick`.

### Направление D: JavaScript `document.dispatchEvent(new MouseEvent(...))`

Эмулировать клик на стороне JS через evaluateJavaScript:

```swift
webView.evaluateJavaScript("""
    document.querySelector('.xterm-helper-textarea')?.focus();
""")
```

xterm.js использует скрытый `<textarea>` для перехвата keyboard input. Прямой фокус на этот элемент может решить проблему.

### Направление E: Переосмыслить архитектуру окна

Вместо NSSplitViewController использовать ручной NSSplitView с двумя subviews. Или использовать NSPanel/popover для сайдбара, оставив WKWebView в основном contentView.

### Направление F: `acceptsFirstResponder` override

Создать subclass WKWebView который возвращает `true` из `acceptsFirstResponder`:

```swift
class FocusableWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Force WebKit content to accept keyboard
        return result
    }
}
```

### Направление G: Исследовать внутреннюю структуру WKWebView

WKWebView содержит внутренний `WKContentView` (на macOS — `WKFlippedView` → `WKWebViewContentView`). Возможно нужно передать фокус именно ему:

```swift
func findContentView(in view: NSView) -> NSView? {
    for subview in view.subviews {
        let name = String(describing: type(of: subview))
        if name.contains("WKContent") || name.contains("WKFlipped") {
            return subview
        }
        if let found = findContentView(in: subview) { return found }
    }
    return nil
}
```

## Текущее состояние кода

**Ветка:** `corcked/swift-phase2b`
**Файлы с попытками фиксов:**
- `apps/desktop-swift/Sources/App/MainWindowController.swift` — `focusWebView()`, `makeFirstResponder`
- `apps/desktop-swift/Sources/App/KeyboardShortcutManager.swift` — NSEvent monitor (работает, не причина бага)

**Что работает:**
- Sidebar — отображение проектов, воркспейсов, переключение
- Terminal rendering — xterm.js рендерит, PTY output приходит
- Git status polling — GitStatusManager запускается (но badges могут не отображаться из-за другого бага)

**Что не работает:**
- Keyboard input в терминал
- Keyboard shortcuts (⌘+1-9 и др.)
- Всё связанное с клавиатурой

## Рекомендация

Наиболее перспективные направления по убыванию вероятности успеха:

1. **Направление D** (JS focus на `.xterm-helper-textarea`) — самый простой, не требует изменений в AppKit архитектуре
2. **Направление B** (`NSApp.sendEvent`) — правильный synthetic event dispatch
3. **Направление G** (фокус на внутренний WKContentView) — low-level но надёжный
4. **Направление A** (убрать container NSView) — может одновременно решить проблему и упростить код
