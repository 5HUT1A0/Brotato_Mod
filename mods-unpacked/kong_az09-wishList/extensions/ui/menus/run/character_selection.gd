extends "res://ui/menus/run/character_selection.gd"

# 注意：不要在这里调 ._ready()。Godot 3 对 _ready 这类回调是 multilevel 调用的，
# 父类 _ready 会自动执行（本项目里没有任何地方显式调 ._ready()），再调一次会跑两遍。
#
# 本扩展负责两件事：
#   1. 在玩法选项面板上放一个「愿望单」按钮，点开 ui/wishlist_panel.gd 那个面板；
#   2. 判断「现在想给哪个角色配愿望单」，把角色 id 传给面板（愿望单是按角色分开的）。

const WishlistPanelScript = preload("res://mods-unpacked/kong_az09-wishList/ui/wishlist_panel.gd")

var _wishlist_button: Button
var _wishlist_panel: Popup

# 最近悬停/聚焦到的角色格子。
#
# 为什么不直接读 _player_characters[0]：solo 下「点角色 = 立刻离开这一屏」——
# _set_selected_element 在单人时同步调 _on_selections_completed() 切场景
#（base_selection.gd:151-172），所以 _player_characters[0] 只在那一帧有值，
# 玩家根本没有「选中了但还没出发」的中间态。于是「想给谁配愿望单」只能看
# 鼠标/焦点停在哪个格子上，这跟商店那边现算 get_player_character(0) 是两回事。
var _hovered_character_element = null


func _ready() -> void :
	# 延迟一帧：本扩展的 _ready 会先于父类执行（multilevel 由派生到基类），
	# 而 _run_options_panel_content 是父类的 onready 变量，此刻不一定已赋值。
	call_deferred("_init_wishlist_ui")


func _init_wishlist_ui() -> void :
	# 动态建控件，参照本文件的 _init_play_mode_ui()
	_wishlist_button = MyMenuButton.new()
	_wishlist_button.name = "WishlistButton"
	_wishlist_button.connect("pressed", self, "_on_WishlistButton_pressed")
	_run_options_panel_content.add_child(_wishlist_button)

	# 父类 _ready 已经给每个 inventory 接好了 element_hovered / element_focused
	#（base_selection.gd:45-46），这里只往 0 号上再挂一份自己的 —— connect 是追加，
	# 不会顶掉父类那两个处理函数。
	# 鼠标悬停走 element_hovered，键盘/手柄聚焦走 element_focused，两个都要。
	var inventory: Inventory = _get_inventories()[0]
	inventory.connect("element_hovered", self, "_on_wishlist_character_element")
	inventory.connect("element_focused", self, "_on_wishlist_character_element")

	_wishlist_panel = WishlistPanelScript.new()
	_wishlist_panel.name = "WishlistPanel"
	_wishlist_panel.connect("wishlist_closed", self, "_on_WishlistPanel_closed")
	add_child(_wishlist_panel)

	_refresh_wishlist_button()


func _on_wishlist_character_element(element) -> void :
	# 悬停在未解锁角色 / 随机格 / 不是角色的格子上时按钮保持原样，一点都不动。
	# 这种格子本来就开不了局，跟着变灰变字只会像「点出错了」。
	# 缓存也不更新：留着上一个真正可用的角色，鼠标扫过一片锁着的格子再移到按钮上照样能用。
	if _character_from_element(element) == null:
		return

	# 不在 unhover 时清空：鼠标得先移开网格才够得到「愿望单」按钮，一清空按钮就灰了
	_hovered_character_element = element
	_refresh_wishlist_button()


# 把一个格子解析成「可以配愿望单的角色」；解析不出来返回 null
func _character_from_element(element):
	if element == null:
		return null

	# 随机格和未解锁格都是 special 元素（base_selection.gd:143-146 先 add_special_element
	# 那个随机图标，再 set_elements），而刚进这一屏时焦点正好落在 get_child(0) 也就是随机格上 ——
	# 那个状态天然就等于「还没选角色」，不用另设标志位。
	if element.is_random or element.is_special:
		return null

	var character = element.item
	if character == null or not (character is CharacterData):
		return null
	# 未解锁的角色不该有愿望单（点它也开不了局）
	if character.is_locked:
		return null

	return character


# 现在该给哪个角色配愿望单；没选中任何人时返回 null
func _active_character():
	# 合作模式里点完角色 _player_characters 会有值（solo 下点完就切场景了，留不住）
	if _player_characters[0] != null:
		return _player_characters[0]

	return _character_from_element(_hovered_character_element)


func _refresh_wishlist_button() -> void :
	var character = _active_character()
	if character == null:
		_wishlist_button.text = "愿望单（请先选择角色）"
		_wishlist_button.disabled = true
	else:
		_wishlist_button.text = "愿望单（%s）" % character.get_name_text()
		_wishlist_button.disabled = false


# BaseSelection._input 用这个方法判断 Esc 能否返回标题界面。
# 面板开着的时候要挡住，否则按 Esc 会直接把这一局的选择清掉退回主菜单。
func _can_go_back_with_ui_cancel() -> bool:
	if _wishlist_panel != null and _wishlist_panel.visible:
		return false
	return ._can_go_back_with_ui_cancel()


func _on_WishlistButton_pressed() -> void :
	# 没有角色就不开面板，按钮上已经写着「请先选择角色」了
	var character = _active_character()
	if character == null:
		return

	# 面板是按角色分开存的，打开前必须告诉它这次编辑谁的
	_wishlist_panel.set_character(character.my_id, character.get_name_text())
	_wishlist_panel.open()


func _on_WishlistPanel_closed() -> void :
	_wishlist_button.grab_focus()
