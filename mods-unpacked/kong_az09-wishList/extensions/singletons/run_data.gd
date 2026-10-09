extends "res://singletons/run_data.gd"

# 愿望单（二期）：按角色分仓的愿望单库 + 槽位存档。
#
# 放在 RunData 这个 autoload 上的理由：
# 商店爱心问的是「这一局当前角色想要什么」，选角界面和局内两边都要能问到；
# 而槽位是跨局跨角色的配置，得落盘。两者共用一份文件、一套格式，放一起最省事。
# 一期的存读档原本在 ui/wishlist_panel.gd 里，二期搬过来是因为
# 商店爱心不该依赖「玩家这次开没开过面板」。
#
# 内存里是 hash（int），存档里是 id 字符串（道具 my_id / 武器 weapon_id）——
# hash 就是 String.hash()，存 id 既能反查又好手工改文件。
# 两边换算都走官方接口：算出 hash 用 Keys.generate_hash（原版 _generate_hashes 用的就是它），
# 反查 id 用 ItemService.is_item_id / is_weapon_id + get_item_from_id / get_weapon_from_weapon_id，
# 不自己遍历 items/weapons 建表 —— 游戏更新动了内容，这边跟着走。
#
# ⚠️ 武器记的是 weapon_id_hash（家族 hash），不是 my_id_hash：
# 一个武器家族有 4 阶，各阶是独立资源，my_id 带阶数后缀 ——
# weapons/melee/cactus_mace/1..4 的 my_id 分别是 weapon_cacti_club_1/_2/_3/_4，
# 而 weapon_id 四阶都是 weapon_cacti_club。商店可能卖任意一阶，
# 按 my_id_hash 记的话勾了 1 阶、商店卖 2 阶时爱心就不亮了。
# ProgressData.weapons_unlocked 和图鉴判断解锁用的同样是家族 hash。

const LOG_NAME := "wishList"
const WISHLIST_PATH := "user://kong_az09-wishList_presets.json"
const SLOT_COUNT := 10
const SCHEMA_VERSION := 2

# character_id (角色的 my_id) -> {
#     "current":   Array[int]   这个角色的愿望单（hash）
#     "slots":     Array        10 项，{} 或 {"name": String, "items": Array[id 字符串]}
#     "last_slot": int          这个角色最后用的是哪一槽（面板上那圈绿框），-1 = 没有过
# }
#
# ⚠️ last_slot 是 v2 之后**追加**的可选字段，所以没动 SCHEMA_VERSION：
# 读盘那行的判断是 `version >= SCHEMA_VERSION`，一加号老存档就会掉进「按一期格式迁移」那个分支，
# 整个 characters 表直接丢掉。缺字段的老存档走 _normalize_last_slot() 兜成 -1 就行。
var _store: Dictionary = {}
# 一期存档（version 1 里只有一份全局槽位）迁移过来的内容，
# 给「还没有专属槽位的角色」当起手模板；把存档里的 seed_slots 删掉就关掉这个行为
var _seed_slots: Array = []
var _loaded := false


# --- 读盘 ------------------------------------------------------------------

func _ensure_loaded() -> void :
	if _loaded:
		return
	_loaded = true

	var file: = File.new()
	if file.open(WISHLIST_PATH, File.READ) != OK:
		# 第一次跑就是没有这个文件，不是错误
		return

	var text: = file.get_as_text()
	file.close()

	var parsed = parse_json(text)
	if not (parsed is Dictionary):
		ModLoaderLog.error("愿望单存档格式不对，已忽略：%s" % WISHLIST_PATH, LOG_NAME)
		return

	var version: = int(parsed.get("version", 1))
	if version >= SCHEMA_VERSION:
		_load_v2(parsed)
	else:
		# 一期格式：{"version":1, "slots":[...]}，一份全局槽位。
		# 没有「这是哪个角色存的」这个信息，只能当模板。
		_seed_slots = _normalize_slots(parsed.get("slots", []))


func _load_v2(parsed: Dictionary) -> void :
	# 变量别叫 seed：那是 Godot 3 的内置函数名，当变量名会解析不过
	var raw_seed = parsed.get("seed_slots", [])
	if raw_seed is Array:
		_seed_slots = _normalize_slots(raw_seed)

	var characters = parsed.get("characters", {})
	if not (characters is Dictionary):
		ModLoaderLog.error("愿望单存档的 characters 不是字典，已忽略：%s" % WISHLIST_PATH, LOG_NAME)
		return

	for character_id in characters.keys():
		var raw = characters[character_id]
		if not (raw is Dictionary):
			continue

		var current: Array = []
		var raw_current = raw.get("current", [])
		if raw_current is Array:
			for id in raw_current:
				var item_hash: int = wishlist_hash_for_id(id)
				# empty_hash 是「这个 id 不合法 / 已经不存在了」，不要放进愿望单
				if item_hash != Keys.empty_hash:
					current.push_back(item_hash)

		_store[String(character_id)] = {
			"current": current,
			"slots": _normalize_slots(raw.get("slots", [])),
			"last_slot": _normalize_last_slot(raw.get("last_slot", - 1)),
		}


# --- 落盘 ------------------------------------------------------------------

func save_wishlists() -> void :
	_ensure_loaded()

	var characters: Dictionary = {}
	for character_id in _store.keys():
		var entry: Dictionary = _store[character_id]
		characters[character_id] = {
			"current": _hashes_to_ids(entry["current"]),
			"slots": entry["slots"],
			"last_slot": int(entry.get("last_slot", - 1)),
		}

	var payload: Dictionary = {
		"version": SCHEMA_VERSION,
		"characters": characters,
	}
	if not _seed_slots.empty():
		payload["seed_slots"] = _seed_slots

	var file: = File.new()
	if file.open(WISHLIST_PATH, File.WRITE) != OK:
		ModLoaderLog.error("愿望单存档写入失败：%s" % WISHLIST_PATH, LOG_NAME)
		return

	file.store_string(to_json(payload))
	file.close()


func _hashes_to_ids(hashes) -> Array:
	var ids: Array = []
	if not (hashes is Array):
		return ids

	for item_hash in hashes:
		var id: String = wishlist_id_for_hash(item_hash)
		# 游戏更新删掉了某个条目时，hash 还在但查不到 id，只能丢掉
		if not id.empty():
			ids.push_back(id)

	return ids


# id 字符串 -> hash。
# Keys.generate_hash 本来就是产出 my_id_hash / weapon_id_hash 的那个函数
# （ItemParentData._generate_hashes 里就是 Keys.generate_hash(my_id)），所以这里只是重算一遍。
# ⚠️ 它对纯数字字符串会 assert（hash 就是 text.hash()，数字串有撞车风险），
# 存档被手工改过时不能直接喂进去。
# 武器存的是 weapon_id（家族 id），不是 my_id —— 见文件开头那段说明。
func wishlist_hash_for_id(id) -> int:
	if not (id is String):
		return Keys.empty_hash
	var text: String = id
	if text.empty() or text.is_valid_integer():
		return Keys.empty_hash
	return Keys.generate_hash(text)


# hash -> id 字符串（道具 my_id / 武器 weapon_id），存槽位时用。
#
# 走 ItemService 的官方查表接口，不自己遍历 items/weapons 建表：
# is_item_id / is_weapon_id 就是官方用来回答「这个 hash 现在还有没有对应条目」的，
# 先问它们再取值，是因为 get_item_from_id / get_weapon_from_weapon_id 找不到时会 assert。
# 当前版本里已经没有这个条目时返回空串（调用方据此判「找不到了」）。
func wishlist_id_for_hash(item_hash: int) -> String:
	if ItemService.is_item_id(item_hash):
		return ItemService.get_item_from_id(item_hash).my_id

	# 同一家族 4 阶共用同一个 weapon_id，取哪一阶拿到的字符串都一样
	if ItemService.is_weapon_id(item_hash):
		return ItemService.get_weapon_from_weapon_id(item_hash).weapon_id

	return ""


# --- 条目 ------------------------------------------------------------------

func _empty_slots() -> Array:
	var slots: Array = []
	for _i in range(SLOT_COUNT):
		slots.push_back({})
	return slots


# 存档里的 slots 可能缺项/超长/类型不对，统一补成 10 个 {}
func _normalize_slots(raw) -> Array:
	var slots: Array = []
	if raw is Array:
		for i in range(min(raw.size(), SLOT_COUNT)):
			var slot = raw[i]
			if not (slot is Dictionary):
				slots.push_back({})
				continue
			var items = slot.get("items", [])
			if not (items is Array):
				items = []
			slots.push_back({
				"name": String(slot.get("name", "")),
				"items": items,
			})

	while slots.size() < SLOT_COUNT:
		slots.push_back({})

	return slots


# 存档里的 last_slot 可能没有（老版本）/ 越界 / 被手改成别的类型，统一兜成 -1（= 没有）
func _normalize_last_slot(raw) -> int:
	# JSON 里整个数解析出来是 int，但手改的存档可能写成 4.0 之类，两种都收
	if not (raw is int) and not (raw is float):
		return - 1

	var index: int = int(raw)
	if index < 0 or index >= SLOT_COUNT:
		return - 1
	return index


# 取（必要时建）某个角色的条目。create = false 时只读，不会往库里塞东西。
func _entry(character_id: String, create: bool) -> Dictionary:
	_ensure_loaded()

	if character_id.empty():
		return {}

	if not _store.has(character_id):
		if not create:
			return {}
		var slots: Array
		# 新角色第一次用：继承一期迁移过来的模板（如果还有）
		if _seed_slots.empty():
			slots = _empty_slots()
		else:
			slots = _seed_slots.duplicate(true)
		_store[character_id] = {"current": [], "slots": slots, "last_slot": - 1}

	return _store[character_id]


# --- 对外 -----------------------------------------------------------------

# 面板用：某个角色有没有把这些 hash 标进愿望单
func is_wishlisted_for(character_id: String, item_hash: int) -> bool:
	var entry: Dictionary = _entry(character_id, false)
	if entry.empty():
		return false
	return (entry["current"] as Array).has(item_hash)


# 商店爱心用：这一局当前角色的愿望单里有没有它。
#
# 角色是**现算**的，不另存一个「当前角色 id」—— 读档继续一局时
# 没有任何「选角完成」的钩子会被调用，另存 id 的话愿望单会是空的。
func is_wishlisted(item_hash: int) -> bool:
	if players_data.empty():
		return false

	var character = get_player_character(0)
	if character == null:
		return false

	return is_wishlisted_for(character.my_id, item_hash)


func get_wishlist(character_id: String) -> Array:
	var entry: Dictionary = _entry(character_id, false)
	if entry.empty():
		return []
	return (entry["current"] as Array).duplicate()


func set_wishlist(character_id: String, item_hashes: Array) -> void :
	var entry: Dictionary = _entry(character_id, true)
	if entry.empty():
		return

	entry["current"] = item_hashes.duplicate()
	save_wishlists()


func toggle_wishlist_item(character_id: String, item_hash: int) -> void :
	var entry: Dictionary = _entry(character_id, true)
	if entry.empty():
		return

	var current: Array = entry["current"]
	if current.has(item_hash):
		current.erase(item_hash)
	else:
		current.push_back(item_hash)

	save_wishlists()


func clear_wishlist(character_id: String) -> void :
	var entry: Dictionary = _entry(character_id, true)
	if entry.empty():
		return

	entry["current"] = []
	save_wishlists()


# 返回深拷贝：面板拿它做显示，改完走 set_wishlist_slot() 写回去
func get_wishlist_slots(character_id: String) -> Array:
	var entry: Dictionary = _entry(character_id, true)
	if entry.empty():
		return _empty_slots()
	return (entry["slots"] as Array).duplicate(true)


func set_wishlist_slot(character_id: String, index: int, slot: Dictionary) -> void :
	var entry: Dictionary = _entry(character_id, true)
	if entry.empty() or index < 0 or index >= SLOT_COUNT:
		return

	var slots: Array = entry["slots"]
	while slots.size() < SLOT_COUNT:
		slots.push_back({})

	slots[index] = slot.duplicate(true)
	save_wishlists()


# 这个角色最后使用的是哪一槽（面板上给那一槽套绿框）。-1 = 还没有过。
#
# 和面板里那个「选中的槽位」不是一回事：选中只是「保存/改名要落到哪一槽」这个编辑目标，
# 而这个是「当前愿望单是从哪一槽读进来的」这个事实，跟着角色一起存盘。
func get_wishlist_active_slot(character_id: String) -> int:
	var entry: Dictionary = _entry(character_id, false)
	if entry.empty():
		return - 1
	return int(entry.get("last_slot", - 1))


func set_wishlist_active_slot(character_id: String, index: int) -> void :
	var entry: Dictionary = _entry(character_id, true)
	if entry.empty():
		return

	entry["last_slot"] = _normalize_last_slot(index)
	save_wishlists()


# --- 测试用：F9 开关「必定掉箱子」 -------------------------------------------
#
# 只为稳定验证「拿取键上的愿望单爱心」能不能正常出现（开箱是随机掉落，靠运气太慢），
# 测完整段删掉即可，不影响别的东西。
#
# 用的是游戏自己的调试开关 DebugService.always_drop_crates（调试菜单 Waves 页签里那个
# "Trees Always Drop Crates"，debug_menu.tscn:769）。置 true 之后
# item_service.gd:167-170 会把掉落率和 item_chance 都拉成 1.0：
#   - 掉落率 1.0  → 每杀一个单位都掉
#   - item_chance 1.0 → tier 被强制成 UNCOMMON（打 Boss 是 LEGENDARY，item_service.gd:178-183），
#     而这两个 tier 对应的就是 item_box / legendary_item_box，
#     它们的 to_be_processed_at_end_of_wave = true，所以捡到就会进波末的开箱选择。
# 名字里的 "Trees" 只是历史原因（这函数本来是树掉果子的），实际对所有能掉东西的单位都生效。
#
# 为什么要自己挂一个键：官方那个入口只在 debug build 里能开
# （debug_service.gd:68 有 OS.is_debug_build() 判断），跑正式版按 F2 没反应。
# DebugService 是 autoload，正式版里也在（item_service.gd:169 无条件读它）。
# F9 在本工程的 InputMap 里没有被任何动作占用。
#
# 这段写在这里不会顶掉原版的方法：原版 run_data.gd 没有 _input（确认过），
# 不用像别处那样链式调 ._input(event)。节点定义了 _input，Godot 3 会自动给它开输入处理
#（原版 DebugService._input 也是这么生效的，它并没有显式 set_process_input）。
func _input(event: InputEvent) -> void :
	# is_pressed / is_echo 是 InputEvent 基类自己的方法，直接问就行
	if not event.is_pressed() or event.is_echo():
		return

	# 但 scancode 这类是 InputEventKey 的字段，event 的静态类型是 InputEvent，
	# 取子类成员得先过一道无类型别名，不然分析器不认（同 ui/wishlist_panel.gd 的 _block_ime_navigation）
	var key_event = event
	if not (key_event is InputEventKey):
		return
	# F 键不受键盘布局影响，但两个字段都看一眼更保险
	if key_event.scancode != KEY_F9 and key_event.physical_scancode != KEY_F9:
		return

	DebugService.always_drop_crates = not DebugService.always_drop_crates
	ModLoaderLog.info("必定掉箱子 = %s（F9 再按一次关掉）" % DebugService.always_drop_crates, LOG_NAME)
