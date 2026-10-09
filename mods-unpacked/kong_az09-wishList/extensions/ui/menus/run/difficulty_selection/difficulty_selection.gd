extends "res://ui/menus/run/difficulty_selection/difficulty_selection.gd"

# 难度选择这一屏底部居中的愿望单入口。
#
# 为什么挂在这一屏，而不是选角屏 / 选武器屏：
#   - 选角屏（solo 下点角色 = 立刻切场景）和选武器屏都得靠「悬停 / 场景已经走到哪一步」来认人，
#     这一屏角色早就提交进 RunData 了，直接 get_player_character(0) 就完事；
#   - 最关键的是 **bull 到不了选武器屏**：它的 weapon_slot = 0（bull_effect_5.tres）、
#     starting_items 也是空的，RunData.some_player_has_weapon_slots() 判 false，
#     character_selection.gd:219-223 会直接跳过选武器屏。挂在那边的按钮 bull 永远够不着。
#     难度选择屏是所有角色开局前都要经过的最后一屏（beast_master 走完选武器屏也来这），
#     放这里对全部角色都成立；同时也是开局前最后一次能改愿望单的机会。
#
# 不要在这里调 ._ready()：Godot 3 对 _ready 这类回调是 multilevel 调用的，
# 父类 _ready 会自动执行（本项目里没有任何地方显式调 ._ready()），再调一次会跑两遍。

const WishlistPanelScript = preload("res://mods-unpacked/kong_az09-wishList/ui/wishlist_panel.gd")

# 按钮底边离屏幕底边的距离。这里唯一一个写死的数字：
# 本屏内容（DescriptionContainer + 难度格子那个 ScrollContainer）到 y=980 为止，
# 按钮高 51，往上 30 就从 999 排到 1050，正好落在空白里不压到难度格子。
# 原版哪天把内容往下铺得更长，改这一个数即可。
const BOTTOM_MARGIN := 30.0

var _wishlist_button: Button
var _wishlist_panel: Popup


func _ready() -> void :
	# 延迟一帧：本扩展的 _ready 会先于父类执行（multilevel 由派生到基类），
	# 而 _back_button 是父类的 onready 变量，此刻还没赋值。摆位要靠它，所以整个初始化都推后。
	call_deferred("_init_wishlist_ui")


func _init_wishlist_ui() -> void :
	_wishlist_button = MyMenuButton.new()
	_wishlist_button.name = "WishlistButton"
	_wishlist_button.connect("pressed", self, "_on_WishlistButton_pressed")

	# 屏幕底部居中。尺寸仍旧量 BackButton 的宽高，不写死：
	# 这一屏原版改过好几轮布局，按钮大小跟着原版按钮走，至少和这一屏的其它按钮一样大。
	var width: float = _back_button.margin_right - _back_button.margin_left
	var height: float = _back_button.margin_bottom - _back_button.margin_top

	# 用锚点而不是绝对边距：本屏是 1920×1080 + stretch_mode=2d，锚 0.5/1.0 在别的分辨率上也居中贴底。
	# 锚在 (0.5, 1.0) 之后，边距的含义变成「相对锚点的偏移」—— 横向左右各让出半个宽度就是居中，
	# 纵向从屏幕底边往上量 BOTTOM_MARGIN。
	_wishlist_button.anchor_left = 0.5
	_wishlist_button.anchor_right = 0.5
	_wishlist_button.anchor_top = 1.0
	_wishlist_button.anchor_bottom = 1.0
	_wishlist_button.margin_left = - width * 0.5
	_wishlist_button.margin_right = width * 0.5
	_wishlist_button.margin_bottom = - BOTTOM_MARGIN
	_wishlist_button.margin_top = - BOTTOM_MARGIN - height

	# 加在根节点上（BackButton 也是根节点的直接子节点）。根节点是铺满全屏的 Control，
	# 锚点就是按它算的 —— 「屏幕底部居中」才成立；挂进任何带布局的容器里，锚点都会被容器接管。
	add_child(_wishlist_button)

	# 空方向钉死在自己身上，跟 BackButton 一个待遇（difficulty_selection.gd:27-28 就是这写法）。
	# 挪到底部居中之后，空的是左/右/下这三边；**上面要留着**，
	# 键盘/手柄玩家得能从难度格子往下走到这里，也得能原路走回去。
	# 不钉的话 Godot 会自己找个「最近的」控制走，可能把焦点甩到很远的角落。
	# ⚠️ 这几句必须放在 add_child() 之后：Node.get_path_to() 第一行就是
	# `if !is_inside_tree(): return NodePath("")`，节点还没进树时算出来是空路径（还带一句报错）。
	for margin in [MARGIN_LEFT, MARGIN_RIGHT, MARGIN_BOTTOM]:
		_wishlist_button.set_focus_neighbour(margin, _wishlist_button.get_path_to(_wishlist_button))

	_wishlist_panel = WishlistPanelScript.new()
	_wishlist_panel.name = "WishlistPanel"
	_wishlist_panel.connect("wishlist_closed", self, "_on_WishlistPanel_closed")
	add_child(_wishlist_panel)

	_refresh_wishlist_button()


# 这一屏角色已经提交进 RunData 了，直接取就行
func _active_character():
	if RunData.players_data.empty():
		return null
	return RunData.get_player_character(0)


func _refresh_wishlist_button() -> void:
	var character = _active_character()
	if character == null:
		_wishlist_button.text = "愿望单（没有角色）"
		_wishlist_button.disabled = true
	else:
		_wishlist_button.text = "愿望单（%s）" % character.get_name_text()
		_wishlist_button.disabled = false


# BaseSelection._input 用这个方法判断 Esc 能否退回上一屏（base_selection.gd:76）。
# 面板开着的时候要挡住，否则按 Esc 会走 _go_back() → RunData.revert_all_selections()，
# 把刚选好的角色/武器清掉。
func _can_go_back_with_ui_cancel() -> bool:
	if _wishlist_panel != null and _wishlist_panel.visible:
		return false
	return ._can_go_back_with_ui_cancel()


func _on_WishlistButton_pressed() -> void:
	var character = _active_character()
	if character == null:
		return

	# 面板是按角色分开存的，打开前必须告诉它这次编辑谁的
	_wishlist_panel.set_character(character.my_id, character.get_name_text())
	_wishlist_panel.open()


func _on_WishlistPanel_closed() -> void:
	_wishlist_button.grab_focus()
