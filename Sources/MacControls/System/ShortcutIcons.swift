import AppKit
import SQLite3

/// Shortcut metadata and icons, exactly as the Shortcuts app shows them.
///
/// The icon (background colour + glyph number) is read from the Shortcuts database and drawn with the private
/// WorkflowKit `WFWorkflowIconDrawer`. Everything is best effort: callers fall back to a generic symbol on nil.
final class ShortcutIcons {
	static let shared = ShortcutIcons()

	struct Entry {
		let identifier: String
		let name: String
		let color: Int64
		let glyph: UInt16
	}

	private let databasePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Shortcuts/Shortcuts.sqlite").path
	private var images: [String: NSImage] = [:]

	private typealias InitIcon = @convention(c) (AnyObject, Selector, Int64, UInt16) -> Unmanaged<AnyObject>?
	private typealias PNGData = @convention(c) (AnyClass, Selector, AnyObject, CGSize) -> Unmanaged<NSData>?

	private lazy var workflowKitLoaded: Bool = {
		dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW) != nil
			&& dlopen("/System/Library/PrivateFrameworks/WorkflowUICore.framework/WorkflowUICore", RTLD_NOW) != nil
	}()

	/// Looks a shortcut up by identifier (preferred) or by name.
	func entry(identifier: String, name: String) -> Entry? {
		var db: OpaquePointer?
		guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
			Log.error("Cannot open Shortcuts database: \(String(cString: sqlite3_errmsg(db)))")
			sqlite3_close(db)
			return nil
		}
		defer { sqlite3_close(db) }
		let byIdentifier = !identifier.isEmpty
		let sql = """
			SELECT s.ZWORKFLOWID, s.ZNAME, i.ZBACKGROUNDCOLORVALUE, i.ZGLYPHNUMBER
			FROM ZSHORTCUT s JOIN ZSHORTCUTICON i ON i.Z_PK = s.ZICON
			WHERE \(byIdentifier ? "s.ZWORKFLOWID" : "s.ZNAME") = ? AND IFNULL(s.ZTOMBSTONED, 0) = 0
			LIMIT 1
			"""
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
			Log.error("Shortcuts database query failed: \(String(cString: sqlite3_errmsg(db)))")
			return nil
		}
		defer { sqlite3_finalize(statement) }
		let key = byIdentifier ? identifier : name
		let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
		sqlite3_bind_text(statement, 1, key, -1, transient)
		guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
		return Entry(
			identifier: String(cString: sqlite3_column_text(statement, 0)),
			name: String(cString: sqlite3_column_text(statement, 1)),
			color: sqlite3_column_int64(statement, 2),
			glyph: UInt16(truncatingIfNeeded: sqlite3_column_int(statement, 3))
		)
	}

	/// The shortcut's icon (rounded square with glyph), cached per colour/glyph.
	func image(for entry: Entry) -> NSImage? {
		let key = "\(entry.color)-\(entry.glyph)"
		if let cached = images[key] { return cached }
		guard workflowKitLoaded,
		      let iconClass = NSClassFromString("WFWorkflowIcon"), let drawerClass = NSClassFromString("WFWorkflowIconDrawer")
		else { return nil }

		let initSelector = NSSelectorFromString("initWithBackgroundColorValue:glyphCharacter:")
		let pngSelector = NSSelectorFromString("pngDataForImageWithIcon:size:")
		guard let allocated = (iconClass as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
		      let initIMP = class_getMethodImplementation(iconClass, initSelector),
		      let pngIMP = class_getMethodImplementation(object_getClass(drawerClass), pngSelector),
		      let icon = unsafeBitCast(initIMP, to: InitIcon.self)(allocated, initSelector, entry.color, entry.glyph)?.takeRetainedValue(),
		      let png = unsafeBitCast(pngIMP, to: PNGData.self)(drawerClass, pngSelector, icon, CGSize(width: 144, height: 144))?.takeUnretainedValue(),
		      let image = NSImage(data: png as Data)
		else {
			Log.error("Could not render shortcut icon \(key)")
			return nil
		}
		images[key] = image
		return image
	}
}
