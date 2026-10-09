extends PopupPanel

# 愿望单面板：列出全部道具和武器，点击格子切换「想要」状态；
# 上方是 10 个可命名的组合槽，能把当前愿望单整套存下来、随时读回来。
# 整个 UI 用代码搭，避免在 mod 里手写 .tscn。
# 网格复用游戏现成的 Inventory（它会自动按 element_scene 生成格子）。
#
# 愿望单按角色分开：set_character() 指定这份面板在编辑哪个角色的愿望单。
# 数据全在 RunData（extensions/singletons/run_data.gd）里，本文件只管显示和交互，
# 自己不再读写存档 —— 一期是这边读写的，搬到 RunData 是因为
# 商店爱心不该依赖「玩家这次开没开过面板」。存档格式见那个文件的注释。
#
# 道具和武器分两个页签（武器每个家族只列基阶，理由见 _build_weapon_list()），
# 右侧常驻一张属性卡片，鼠标划过格子就刷新 —— 就是图鉴那套「左网格右详情」。

signal wishlist_closed

const LOG_NAME := "wishList"

const INVENTORY_SCENE := "res://ui/menus/shop/inventory.tscn"
# 图鉴那张「独立详情卡」：根节点是 VBoxContainer，script 就是 ItemDescription，
# 自带 base_theme 和 effect_line。同一个场景道具和武器都能画 ——
# ItemDescription.set_item() 内部按 `item_data is WeaponData` 分支，
# 武器会多出武器数值和武器套装，道具走另一边。
const CARD_SCENE := "res://ui/menus/pages/menu_codex/codex_weapon_description.tscn"
const HEART_COLOR := Color(1.0, 0.45, 0.65)
const HEART_SIZE := 28.0

# max_hp.png 是一颗绿色的心（HP 图标），而 modulate 只能做乘法：
# 绿(0.35, 0.85, 0.45) × 粉(1, 0.45, 0.65) ≈ 灰绿 —— 看着就是灰的，颜色调不回来。
# 游戏里也没有现成的红/粉爱心（hp_regeneration 同样是绿心），所以用一个最小着色器：
# 把原图当形状遮罩，颜色整个换成 HEART_COLOR，原图的明暗留着，不会变成一块死粉。
const HEART_SHADER_CODE := """
shader_type canvas_item;
render_mode unshaded;

uniform vec4 tint : hint_color = vec4(1.0, 0.45, 0.65, 1.0);

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	float luminance = dot(src.rgb, vec3(0.299, 0.587, 0.114));
	COLOR = vec4(tint.rgb * min(luminance * 1.35, 1.0), src.a);
}
"""
const COLUMNS := 10
const MARGIN := 24
# 属性卡片占的最小宽度。再窄就换行得难看，见 _update_columns()
const CARD_MIN_WIDTH := 420.0

# 和 run_data.gd 里的 SLOT_COUNT 保持一致
const SLOT_COUNT := 10
const SLOT_COLUMNS := 5

const HEART_META := "wishlist_heart"

const TAB_ITEMS := 0
const TAB_WEAPONS := 1

# 「这个角色最后使用的愿望单是哪一槽」—— 给那颗槽位按钮套一圈绿框。
# 值存在 RunData 里，跟着角色走，关掉面板再开、乃至重开游戏都还在。
#
# 颜色抄的是 Utils.GOLD_COLOR：原版这个常量名叫 gold，值 "76ff76" 其实是亮绿，
# 游戏 UI 里的绿就是它。自造一个色号容易跟原版界面不搭，跟着用。
const ACTIVE_OUTLINE_COLOR := Color("76ff76")
const ACTIVE_OUTLINE_WIDTH := 3.0
# 圆角和按钮本体对齐（button_normal.tres 的 corner_radius = 12），
# 不然方框套圆钮，四个角会露在外面很出戏
const ACTIVE_OUTLINE_RADIUS := 12
# 往外扩 2px，让它落在按钮外沿而不是压住按钮自己的深色边
const ACTIVE_OUTLINE_EXPAND := 2.0
const ACTIVE_OUTLINE_NODE := "ActiveOutline"

var _inventory: Inventory
var _scroll: ScrollContainer
var _description: ItemDescription
# 卡片标题行里要藏起来的两块（只显示属性，不要图标和名字），见 _build_card()
var _card_icon: Control
var _card_name: Control
var _close_button: Button
var _title: Label
var _status: Label
var _name_input: LineEdit
var _slot_buttons: Array = []
var _tab_buttons: Array = []
var _heart_material: ShaderMaterial # 所有爱心共用一份，着色器只编一次
var _heart_texture: Texture # 同上，爱心本体也只取一次

# 本面板正在编辑哪个角色的愿望单。打开面板前必须由 set_character() 设好
var _character_id := ""
var _character_name := ""

# 两个页签各自的列表，_populate() 里建一次
var _item_list: Array = []
var _weapon_list: Array = []
var _active_tab := TAB_ITEMS

# 10 个槽位，每项是 {} （空槽）或 {"name": String, "items": Array[String]}
# 是 RunData 里那份的深拷贝，改完调 RunData.set_wishlist_slot() 写回去
var _presets: Array = []
var _selected_slot := 0
# 这个角色最后使用的是哪一槽（-1 = 还没有过），绿框按它亮。
# 和 _selected_slot 分开记：_selected_slot 是「保存/改名要落到哪一槽」这个编辑目标，
# 打开面板时由 set_character() 初始化成 _active_slot（没有过就是 0 号），
# 之后玩家点哪个槽位按钮就跟着走。
# 真值存在 RunData 里（跟着角色走），这里只是本次打开的一份拷贝。
var _active_slot := -1
# 10 个槽位按钮上的绿框 Panel，下标同 _slot_buttons
var _slot_outlines: Array = []
# 面板打开期间被临时停掉的 FocusEmulator，元素是 [节点, 原来的 focused_control]
var _paused_emulators: Array = []


func _ready() -> void:
	popup_exclusive = true
	connect("popup_hide", self, "_on_popup_hide")
	_build_ui()
	# _refresh_slot_buttons() 会按下标读 _presets，先垫上空的
	_presets = _empty_presets()
	_refresh_slot_buttons()


# 打开前必须调，告诉面板这次编辑谁的愿望单
func set_character(character_id: String, character_name: String) -> void:
	_character_id = character_id
	_character_name = character_name
	_presets = RunData.get_wishlist_slots(_character_id)
	# 绿框亮在这个角色上次用的那一槽上，不是新的一局就忘了
	_active_slot = RunData.get_wishlist_active_slot(_character_id)
	# 编辑目标（名字框 + 保存/改名/清空此槽）默认落在同一槽上：
	# 面板一开，手上这份愿望单就是从那一槽读进来的，那三个按钮就该对着它，
	# 不该对着 0 号 —— 否则得先点一下槽位按钮才能正确改动，白挨一次手滑。
	# 这个角色还没有过「最后用的槽」（-1）时才退回 0 号。
	_selected_slot = _active_slot if _active_slot >= 0 else 0


func open() -> void:
	popup_centered_ratio(0.9)
	_populate()
	# 落在这个角色「最后用的那一槽」（set_character() 定好的），不是硬编码 0 号
	_select_slot(_selected_slot)
	_close_button.grab_focus()
	# 面板开着的时候把 FocusEmulator 关掉，理由见文件末尾那段注释
	call_deferred("_pause_focus_emulators")
	# 首选在这里也算一次列数：resized 信号在首次布局后才会来
	call_deferred("_update_columns")


func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action("ui_cancel"):
		# 按下和松开都要吃掉，但只在松开时真的关。
		#
		# BaseSelection._input 是监听 ui_cancel 的「松开」来退回标题界面的
		# （base_selection.gd:76）。要是我们在按下时就 hide()，等松开事件到达时面板已经不可见，
		# 扩展里那个 _can_go_back_with_ui_cancel() 就会放行，这一局选好的角色直接被清掉。
		get_tree().set_input_as_handled()
		if event.is_action_released("ui_cancel"):
			hide()
		return

	if _name_input.has_focus():
		_block_ime_navigation(event)


# 中文输入法打字会变成「操作 UI」，元凶在这儿。
#
# 输入法把字母吞掉时（合成中），引擎送下来的按键 unicode 是 0 —— 没有字符，
# 但 physical_scancode 还是字母本身。而 project.godot 里 ui_up/ui_down/ui_left/ui_right
# 就是照 physical_scancode 绑的 87(W)/83(S)/65(A)/68(D)，于是 Viewport 内置的方向键导航
# 认得出它，把打字的按键当成「选菜单」，焦点直接从输入框跳到旁边的商店格子上，
# 后面的按键就全打在那些格子上了。
#
# FocusEmulator 停了也拦不住 —— 这套导航是引擎自己在 Viewport 里做的，不经过它。
# 对输入框来说这种按键本来也没有字符可收，直接吃掉。
func _block_ime_navigation(event) -> void:
	# event 的静态类型是 InputEvent，取子类成员要用无类型别名，不然分析器不认
	var key_event = event
	if not (key_event is InputEventKey):
		return
	if not key_event.is_pressed() or key_event.is_echo():
		return
	# 带 Ctrl/Alt/Win 的是快捷键（比如 Ctrl+V 粘名字），不拦
	if key_event.control or key_event.alt or key_event.meta:
		return
	# 有字符就说明不是被输入法吞掉的那种，交给输入框自己处理
	if key_event.unicode != 0:
		return
	# 和 InputMap 认键用的是同一批字段：两处都不是字母，这键本来也匹配不上方向动作
	if not (_is_letter_scancode(key_event.physical_scancode) or _is_letter_scancode(key_event.scancode)):
		return

	get_tree().set_input_as_handled()


func _is_letter_scancode(code) -> bool:
	return code >= KEY_A and code <= KEY_Z


# --- 构建 UI ---------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side in ["left", "top", "right", "bottom"]:
		margin.add_constant_override("margin_" + side, MARGIN)
	add_child(margin)

	var layout := VBoxContainer.new()
	layout.name = "Layout"
	layout.add_constant_override("separation", 12)
	margin.add_child(layout)

	_title = Label.new()
	_title.name = "Title"
	_title.align = Label.ALIGN_CENTER
	layout.add_child(_title)

	_build_slot_grid(layout)
	_build_name_row(layout)

	_status = Label.new()
	_status.name = "Status"
	_status.align = Label.ALIGN_CENTER
	layout.add_child(_status)

	_build_tabs(layout)

	# 左网格右详情，和图鉴一个布局
	var body := HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_constant_override("separation", 16)
	layout.add_child(body)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 窗口宽度不定，列数按实测宽度算，见 _update_columns()
	_scroll.connect("resized", self, "_update_columns")
	body.add_child(_scroll)

	_inventory = load(INVENTORY_SCENE).instance()
	_inventory.name = "Inventory"
	_inventory.columns = COLUMNS
	# inventory.tscn 里写死了居中用的负 margin，放进 ScrollContainer 前要清掉
	_inventory.anchor_left = 0.0
	_inventory.anchor_top = 0.0
	_inventory.anchor_right = 0.0
	_inventory.anchor_bottom = 0.0
	_inventory.margin_left = 0.0
	_inventory.margin_top = 0.0
	_inventory.margin_right = 0.0
	_inventory.margin_bottom = 0.0
	_scroll.add_child(_inventory)
	_inventory.connect("element_pressed", self, "_on_element_pressed")
	# 悬停和聚焦都刷卡片：鼠标只走 element_hovered，方向键/手柄只走 element_focused
	_inventory.connect("element_hovered", self, "_on_element_hovered")
	_inventory.connect("element_focused", self, "_on_element_hovered")

	_build_card(body)

	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.alignment = BoxContainer.ALIGN_CENTER
	buttons.add_constant_override("separation", 24)
	layout.add_child(buttons)

	var clear_button := MyMenuButton.new()
	clear_button.text = "清空当前愿望单"
	_bind_hint(clear_button, "只清空这一局正在用的愿望单，不动已存的槽位")
	clear_button.connect("pressed", self, "_on_ClearButton_pressed")
	buttons.add_child(clear_button)

	_close_button = MyMenuButton.new()
	_close_button.text = "关闭"
	_close_button.connect("pressed", self, "_on_CloseButton_pressed")
	buttons.add_child(_close_button)


# 道具 / 武器两个页签。选中态沿用本面板槽位按钮那套：压暗未选中的 + 给选中的加「▶ 」，
# 不引入新的视觉语言（也没有别的图标素材可用）。
func _build_tabs(layout: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "Tabs"
	row.alignment = BoxContainer.ALIGN_CENTER
	row.add_constant_override("separation", 24)
	layout.add_child(row)

	for i in [TAB_ITEMS, TAB_WEAPONS]:
		var button := MyMenuButton.new()
		button.name = "TabButton%d" % i
		button.rect_min_size = Vector2(160, 36)
		button.connect("pressed", self, "_on_TabButton_pressed", [i])
		row.add_child(button)
		_tab_buttons.push_back(button)

	var weapon_hint := "列出全部武器。每个家族只列基阶 —— 勾一个等于勾了整条升级线，商店里任何一阶都会亮爱心"
	_bind_hint(_tab_buttons[TAB_ITEMS], "列出全部道具")
	_bind_hint(_tab_buttons[TAB_WEAPONS], weapon_hint)
	_refresh_tab_buttons()


# 右侧常驻的属性卡片，只显示属性。
# 直接用图鉴那张场景（根节点就是 ItemDescription）：expand_indefinitely 保持 true，
# 内容不内部截断，由外面这层 ScrollContainer 滚；不用像 item_description.tscn 那样
# 在 add_child 前改导出变量（那个场景是弹窗形态，带居中锚点和 -960/-540 的 margin）。
func _build_card(parent: Control) -> void:
	var holder := PanelContainer.new()
	holder.name = "CardHolder"
	holder.rect_min_size = Vector2(CARD_MIN_WIDTH, 0)
	parent.add_child(holder)

	var card_scroll := ScrollContainer.new()
	card_scroll.name = "CardScroll"
	holder.add_child(card_scroll)

	_description = load(CARD_SCENE).instance()
	_description.name = "Description"

	# 这三项都是图鉴专用的开关，卡片只显示属性，全关掉：
	#
	# show_player_stats：「已购买 N 次 / 价格 N」两行，是 _get_item_player_stats_description()
	#   给的，纯图鉴统计，跟属性没关系。
	# hide_description_if_locked_in_codex：图鉴里「没买过就只显示『再买 N 次解锁』、
	#   不显示效果」是防剧透。搬到愿望单就废了 —— 想加进愿望单的本来就是还没买的，
	#   不关的话整张卡全是「再买 1 次解锁」。
	# silhouette_locked_items：同一个道理，没买过的会被打成「???」+ 图标涂黑 + 类别清空。
	#
	# 这三个都是 set_item() 执行时现读的（不是 _ready），所以什么时候设都行。
	_description.show_player_stats = false
	_description.hide_description_if_locked_in_codex = false
	_description.silhouette_locked_items = false

	card_scroll.add_child(_description)

	# 图标和名字那行不要，卡片里只留属性。
	# Category（ITEM / UNIQUE / 武器套装名）和 Name 同在 HBoxContainer 里那个 VBoxContainer 下，
	# 是各自独立的节点，所以只藏 IconPanel 和 Name，别把整个 HBoxContainer 藏了。
	# 用 %唯一名 取，和 item_description.gd 自己取的方式一致，比写死路径抗改。
	_card_icon = _description.get_node_or_null("%IconPanel")
	_card_name = _description.get_node_or_null("%Name")
	_set_card_header_visible(false)

	# 卡片左上角那个 Category 是个 Button（图鉴里点它切分类）。这里没接任何东西，
	# 让它留在焦点链表里只会把方向键导航引到一张只读卡片上，直接摘掉。
	var category = _description.get_node_or_null("%Category")
	if category is BaseButton:
		category.focus_mode = Control.FOCUS_NONE


# 锁着的条目只有「??? + 锁图标」这一块内容，而它正是藏在标题行里的东西，
# 所以这时候要把标题行临时放出来，不然卡片是空的（见 _update_card）。
# 藏起来的控件会被 Container 跳过排版，所以藏了就是真的不占位置，不用管布局。
func _set_card_header_visible(show_header: bool) -> void:
	if _card_icon != null:
		_card_icon.visible = show_header
	if _card_name != null:
		_card_name.visible = show_header


# 窗口宽度不定，列数按 ScrollContainer 实测宽度算 ——
# 写死列数的话，窄屏上右边那张卡片会把网格挤出去。
func _update_columns() -> void:
	if _scroll == null or _inventory == null:
		return

	var available: float = _scroll.rect_size.x
	if available <= 0.0:
		return

	# 格子尺寸和行距都问 Inventory 自己，不抄数字 —— 原版的列数就是这么算的
	# （inventory_container.gd:140-148 的 _get_capacity()，写法一样）：
	#   element_size 是它的导出变量（inventory.gd:28，默认值就是 Utils.BASE_INVENTORY_ELEMENT_SIZE，
	#     哪天哪个场景改了尺寸都跟得上）；
	#   hseparation 是 GridContainer 的主题常量（inventory.tscn:18 给的是 10）。
	# 注意取常量的方法名：Godot 3 是 get_constant()，get_theme_constant() 是 Godot 4 的叫法，
	# 这里要是写成 4 的那套就是运行时报错（原版全工程用的都是 get_constant）。
	# 下限 8 是兜底（拿不到这个常量时返回 0，算出来的列数会把网格挤出可视区）。
	var per_element: float = _inventory.element_size.x + max(_inventory.get_constant("hseparation"), 8)
	# 外层 int()：GDScript 3 的 max() 分析器上返回 float，直接赋给 columns 会报窄化警告
	_inventory.columns = int(max(4, int(available / per_element)))
	# 列数变了，方向键的邻居关系要重算
	_inventory.queue_set_focus_neighbours()


func _build_slot_grid(layout: VBoxContainer) -> void:
	var grid := GridContainer.new()
	grid.name = "SlotGrid"
	grid.columns = SLOT_COLUMNS
	grid.add_constant_override("hseparation", 8)
	grid.add_constant_override("vseparation", 8)
	layout.add_child(grid)

	for i in range(SLOT_COUNT):
		var slot_button := MyMenuButton.new()
		slot_button.name = "SlotButton%d" % (i + 1)
		slot_button.rect_min_size = Vector2(0, 36)
		slot_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# clip_text 让按钮的最小宽度不再取决于文字长度（Button 的最小宽度直接算成 0），
		# 于是名字再长也撑不宽格子，5 列始终等分面板宽度。
		# 代价是长名字会被裁掉 —— 完整内容改在悬停时显示，见 _refresh_slot_buttons()。
		slot_button.clip_text = true
		slot_button.connect("pressed", self, "_on_SlotButton_pressed", [i])
		grid.add_child(slot_button)
		_slot_buttons.push_back(slot_button)
		_slot_outlines.push_back(_make_slot_outline(slot_button))


# 「正在用的这一槽」那圈绿框。
#
# 用 Panel 而不是 get_stylebox("normal") 覆写：按钮的 normal 是 StyleBoxFlat
# 黑底 + 圆角，覆写掉背景就没了。挂一个 draw_center = false 的 StyleBoxFlat 做子节点，
# 画在父节点之后（Button 不是 Container，子节点锚点铺满即可），只画边不画底。
func _make_slot_outline(button: Button) -> Panel:
	var outline := Panel.new()
	outline.name = ACTIVE_OUTLINE_NODE
	outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outline.anchor_right = 1.0
	outline.anchor_bottom = 1.0

	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.border_color = ACTIVE_OUTLINE_COLOR
	box.set_border_width_all(int(ACTIVE_OUTLINE_WIDTH))
	box.set_corner_radius_all(ACTIVE_OUTLINE_RADIUS)
	# 往外扩出去，别压住按钮自己的边
	box.set_expand_margin_all(ACTIVE_OUTLINE_EXPAND)
	outline.add_stylebox_override("panel", box)

	outline.visible = false
	button.add_child(outline)
	return outline


func _build_name_row(layout: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "NameRow"
	row.add_constant_override("separation", 12)
	layout.add_child(row)

	var name_label := Label.new()
	name_label.text = "名字"
	row.add_child(name_label)

	_name_input = LineEdit.new()
	_name_input.name = "NameInput"
	_name_input.max_length = 24
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_name_input()
	row.add_child(_name_input)

	row.add_child(_make_action_button(
		"保存到此槽", "用当前愿望单覆盖选中的槽位，名字取左边输入框", "_on_SaveButton_pressed"))
	row.add_child(_make_action_button(
		"只改名", "只改选中槽位的名字，不动里面的道具", "_on_RenameButton_pressed"))
	row.add_child(_make_action_button(
		"清空此槽", "把选中的槽位删掉", "_on_DeleteButton_pressed"))


func _make_action_button(text: String, hint: String, method: String) -> Button:
	var button := MyMenuButton.new()
	button.text = text
	_bind_hint(button, hint)
	button.connect("pressed", self, method)
	return button


# 本面板一律不用 hint_tooltip，改把提示写到槽位下面那行状态文字里。
#
# 理由：Godot 3 的 tooltip 是个黑盒 —— 弹窗由 Viewport 临时造出来，样式要另配
# TooltipPanel / TooltipLabel 两个主题项，而且 3.x 上「主题套了不生效」是已知问题
# （godotengine/godot#25058，嵌套场景里会退回默认样式）。这个工程更是从没用过
# hint_tooltip（原版 0 处），主题里也没有那两项 —— 结果就是弹出来一个黑底黑字的框。
#
# 状态文字用的是游戏自己的 Label 样式，稳定、看得清，中文也正常。
const HINT_META := "wishlist_hint"


func _bind_hint(control: Control, hint: String) -> void:
	control.set_meta(HINT_META, hint)
	# _refresh_slot_buttons() 每次都会调过来，别重复连接
	if not control.is_connected("mouse_entered", self, "_on_Control_mouse_entered"):
		control.connect("mouse_entered", self, "_on_Control_mouse_entered", [control])


func _on_Control_mouse_entered(control: Control) -> void:
	if control.has_meta(HINT_META):
		_set_status(String(control.get_meta(HINT_META)))


# Godot 默认主题的 LineEdit 是灰底，套在这套 UI 里太突兀；游戏自己的主题里没有
# LineEdit 样式（原版只有 bug 上报窗口用 TextEdit），所以这里手动补一份。
func _style_name_input() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.10, 0.10, 0.14, 0.9)
	background.border_color = Color(0.9, 0.75, 0.85, 0.6)
	background.set_border_width_all(2)
	background.set_corner_radius_all(4)
	background.content_margin_left = 8
	background.content_margin_right = 8

	_name_input.add_stylebox_override("normal", background)
	_name_input.add_stylebox_override("focus", background)
	_name_input.add_color_override("font_color", Color(1, 1, 1))
	_name_input.add_color_override("font_placeholder_color", Color(1, 1, 1, 0.35))
	_name_input.add_color_override("caret_color", Color(1, 1, 1))
	_name_input.add_color_override("selection_color", HEART_COLOR)


# --- 当前愿望单 -------------------------------------------------------------

# 两份列表都建好，切页签时就不用重算
func _populate() -> void:
	_build_item_list()
	_build_weapon_list()
	# 存槽位时要把 hash 换回 id，读槽位反过来 —— 两个方向都走 RunData 里那两个函数
	# （wishlist_id_for_hash / wishlist_hash_for_id），它们内部用的是 ItemService 的官方查表接口，
	# 面板这边不再自己维护一张「hash -> id」的映射表：那张表是启动时照着当时的 items/weapons
	# 建出来的，游戏更新后表就旧了，而查表接口永远跟着当下的内容走。
	_active_tab = TAB_ITEMS
	_show_active_tab()
	_refresh_title()


func _build_item_list() -> void:
	_item_list = ItemService.items.duplicate()
	_item_list.sort_custom(self, "_sort_by_tier")

	for item in _item_list:
		# hash 走官方 getter：裸字段 my_id_hash 是 onready 的，没生成过就是 empty_hash，
		# get_my_id_hash() 会兜底重算（和武器那边的 get_weapon_id_hash 一个道理）
		item.is_locked = not ProgressData.items_unlocked.has(item.get_my_id_hash())


# 武器每个家族只列基阶，和图鉴一个规矩（menu_codex.gd:74-94）：
# 一个家族 4 阶、各阶都是独立资源，my_id 带阶数后缀（weapon_cacti_club_1/_2/_3/_4），
# 全列出来就是同一把武器重复 4 条。
# previous_upgrade 是 ItemService._ready() 拿 upgrades_into 反向接好的，
# 只有家族里的基阶是 null。
func _build_weapon_list() -> void:
	var all_weapons: Array = ItemService.weapons.duplicate()
	all_weapons.sort_custom(self, "_sort_by_tier")

	# 图鉴那边这个变量忘了初始化就直接用，这里给个真数组
	_weapon_list = []
	for weapon in all_weapons:
		if weapon.previous_upgrade != null:
			continue
		# 解锁判断用家族 hash，和 ProgressData.weapons_unlocked 里存的、图鉴用的都是同一个
		weapon.is_locked = not ProgressData.weapons_unlocked.has(weapon.get_weapon_id_hash())
		_weapon_list.push_back(weapon)


func _sort_by_tier(a, b) -> bool:
	return a.tier < b.tier


func _active_list() -> Array:
	return _weapon_list if _active_tab == TAB_WEAPONS else _item_list


# 一个 Inventory 复用两个页签：set_elements 会就地改元素的 item 并重建格子，
# 所以切页签后爱心必须整个重建一遍（_decorate_elements 会给新格子挂爱心）。
func _show_active_tab() -> void:
	_inventory.set_elements(_active_list())
	_decorate_elements()
	_refresh_tab_buttons()
	# 照图鉴的做法：切完把卡片刷成新列表的第一格，免得右边停在上一个页签的条目上
	if _inventory.get_child_count() > 0:
		_update_card(_inventory.get_child(0))


func _on_TabButton_pressed(index: int) -> void:
	if index == _active_tab:
		return
	_active_tab = index
	_show_active_tab()


func _refresh_tab_buttons() -> void:
	var labels := ["道具", "武器"]
	for i in range(_tab_buttons.size()):
		var button: Button = _tab_buttons[i]
		button.text = ("▶ " + labels[i]) if i == _active_tab else labels[i]
		button.modulate = Color(1, 1, 1) if i == _active_tab else Color(1, 1, 1, 0.55)


func _refresh_title() -> void:
	_title.text = "「%s」的愿望单（已选 %d 件）" % [
		_character_name, RunData.get_wishlist(_character_id).size()]


# 给每个可选的格子挂一个爱心，用它表示「已加入愿望单」
func _decorate_elements() -> void:
	for element in _inventory.get_children():
		if not element is InventoryElement:
			continue

		var heart := _create_heart(element)
		if heart == null:
			continue

		element.add_child(heart)
		element.set_meta(HEART_META, heart)
		_update_heart(element)


# 换色靠材质（见 HEART_SHADER_CODE 上面的说明），不是 modulate
func _make_heart_material() -> ShaderMaterial:
	if _heart_material != null:
		return _heart_material

	var shader := Shader.new()
	shader.code = HEART_SHADER_CODE
	_heart_material = ShaderMaterial.new()
	_heart_material.shader = shader
	# 颜色以 HEART_COLOR 为准：着色器里那份默认值只是兜底
	_heart_material.set_shader_param("tint", HEART_COLOR)
	return _heart_material


# 爱心本体（max_hp 那颗小绿心）走官方接口取：ItemService.stats 里 stat_max_hp 那条的小图标。
# 不写死 preload("res://items/stats/max_hp.png")：preload 是**解析期**的，
# 游戏更新哪天把图标挪个位置，整个脚本就编译不过 —— mod 跟着一起出事。
# 走这条路最差只是返回 null（那就少一颗心），mod 照样能跑。
# 这段和商店、开箱那两份是同一个，重复一份的理由见 shop_items_container.gd 开头那段说明。
func _get_heart_texture() -> Texture:
	if _heart_texture == null:
		_heart_texture = ItemService.get_stat_small_icon(Keys.stat_max_hp_hash)
	return _heart_texture


func _create_heart(element: InventoryElement) -> TextureRect:
	# 锁着的道具不会出现在商店里，加了也没用；special 格子是锁图标本身
	if element.item == null or element.is_special or element.item.is_locked:
		return null

	# 取不到图标就不挂爱心（正常玩不会走到这儿，只有游戏改掉属性表才会）
	var texture: Texture = _get_heart_texture()
	if texture == null:
		return null

	var heart := TextureRect.new()
	heart.name = "WishlistHeart"
	heart.texture = texture
	heart.material = _make_heart_material()
	heart.expand = true
	heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	heart.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heart.anchor_left = 1.0
	heart.anchor_right = 1.0
	heart.margin_left = - HEART_SIZE
	heart.margin_right = 0.0
	heart.margin_top = 0.0
	heart.margin_bottom = HEART_SIZE
	return heart


func _update_heart(element: InventoryElement) -> void:
	if not element.has_meta(HEART_META):
		return

	var heart: TextureRect = element.get_meta(HEART_META)
	heart.visible = RunData.is_wishlisted_for(_character_id, _wishlist_key(element.item))


# 道具记 my_id_hash，武器记家族 hash（weapon_id_hash）：
# 一个武器家族有 4 阶，各阶是独立资源，my_id 带阶数后缀 ——
# weapon_cacti_club_1/_2/_3/_4，而 weapon_id 四阶都是 weapon_cacti_club。
# 商店可能卖任意一阶，按 my_id_hash 记的话勾了 1 阶、商店卖 2 阶时爱心就不亮了。
# 这段和 extensions/ui/menus/shop/shop_items_container.gd 里那份是同一个，
# 重复一份的理由见那个文件开头那段说明。
func _wishlist_key(data) -> int:
	if data is WeaponData:
		return data.get_weapon_id_hash()
	return data.get_my_id_hash()


func _refresh_all_hearts() -> void:
	for element in _inventory.get_children():
		if element is InventoryElement:
			_update_heart(element)
	_refresh_title()


# --- 槽位 -----------------------------------------------------------------

func _default_slot_name(index: int) -> String:
	return "组合 %d" % (index + 1)


func _slot_items(slot: Dictionary) -> Array:
	# 存档是手改过的 JSON 时 items 可能是任意类型，这里兜一下
	var items = slot.get("items", [])
	return (items if items is Array else [])


func _is_slot_filled(slot: Dictionary) -> bool:
	return not _slot_items(slot).empty()


func _select_slot(index: int) -> void:
	_selected_slot = index
	_name_input.placeholder_text = _default_slot_name(index)
	_name_input.text = String(_presets[index].get("name", ""))
	_refresh_slot_buttons()


func _refresh_slot_buttons() -> void:
	for i in range(_slot_buttons.size()):
		var slot: Dictionary = _presets[i]
		var items: Array = _slot_items(slot)
		var filled := _is_slot_filled(slot)

		var slot_name: String = String(slot.get("name", ""))
		if slot_name.empty():
			slot_name = _default_slot_name(i)

		var label: String = slot_name
		if filled:
			label += " (%d)" % items.size()
		if i == _selected_slot:
			label = "▶ " + label

		var button: Button = _slot_buttons[i]
		button.text = label
		button.modulate = (Color(1, 1, 1) if filled else Color(1, 1, 1, 0.55))

		# 绿框只标「这个角色最后用的是这一槽」，和 ▶（编辑目标）是两回事：
		# 打开面板时 ▶ 默认落在 0 号上，但那是「保存/改名要落到哪」，不代表刚用过 0 号。
		if i < _slot_outlines.size():
			_slot_outlines[i].visible = (i == _active_slot)

		# 按钮开着 clip_text，名字长了会被裁掉，完整内容（和件数）放悬停提示
		var tip: String = "槽位 %d「%s」" % [i + 1, slot_name]
		if filled:
			tip += "，共 %d 件" % items.size()
		else:
			tip += "，空槽"
		_bind_hint(button, tip)


func _set_status(text: String) -> void:
	_status.text = text


# --- 槽位动作 --------------------------------------------------------------

# 点槽位 = 选中它 + 立刻把这一槽读进当前愿望单（原来还要再点一次「读取此槽」，两步）
func _on_SlotButton_pressed(index: int) -> void:
	_select_slot(index)
	_load_slot(index)


func _on_SaveButton_pressed() -> void:
	# 存的是 id 字符串不是 hash：hash 是 String.hash()，游戏更新后会跟着内容变，
	# 存 id 既能反查又好手工改文件（读回来由 RunData 换算）
	var items: Array = []
	for item_hash in RunData.get_wishlist(_character_id):
		# hash -> id 交给 RunData（内部走 ItemService.is_item_id / is_weapon_id + 查表）。
		# 查不到说明这条已经不在当前版本里了，存不进槽位，跳过
		var id: String = RunData.wishlist_id_for_hash(item_hash)
		if not id.empty():
			items.push_back(id)

	var slot_name: String = _name_input.text.strip_edges()
	if slot_name.empty():
		slot_name = _default_slot_name(_selected_slot)

	var slot: Dictionary = {"name": slot_name, "items": items}
	_presets[_selected_slot] = slot
	RunData.set_wishlist_slot(_character_id, _selected_slot, slot)
	_refresh_slot_buttons()

	if items.empty():
		_set_status("槽位 %d 已存为「%s」，但当前愿望单是空的" % [_selected_slot + 1, slot_name])
	else:
		_set_status("已把 %d 件存进槽位 %d「%s」" % [items.size(), _selected_slot + 1, slot_name])


func _on_RenameButton_pressed() -> void:
	var slot: Dictionary = _presets[_selected_slot]
	if not _is_slot_filled(slot):
		_set_status("槽位 %d 是空的，没有名字可改" % (_selected_slot + 1))
		return

	var slot_name: String = _name_input.text.strip_edges()
	if slot_name.empty():
		slot_name = _default_slot_name(_selected_slot)

	slot["name"] = slot_name
	RunData.set_wishlist_slot(_character_id, _selected_slot, slot)
	_refresh_slot_buttons()
	_set_status("槽位 %d 已改名为「%s」" % [_selected_slot + 1, slot_name])


# 把某个槽位读进当前愿望单。由 _on_SlotButton_pressed() 调用（没有单独的读取按钮了）。
# 空槽不读 —— 免得手滑点一下就把正在编辑的愿望单清空，只提示一句。
func _load_slot(index: int) -> void:
	var ids: Array = _slot_items(_presets[index])
	if ids.empty():
		# 空槽不读，绿框也就不动 —— 玩家手上的还是原来那一槽
		_set_status("槽位 %d 是空的，没有可读的内容" % (index + 1))
		return

	var hashes: Array = []
	var missing := 0
	for id in ids:
		var text: String = String(id)
		# id -> hash 交给 RunData（内部就是 Keys.generate_hash，原版 _generate_hashes 用的那个）。
		# 它对空串和纯数字串是不能直接喂的（Keys.generate_hash 里有 assert），
		# 存档被手改成这种值时 RunData 会返回 empty_hash，这里直接算作找不到
		var item_hash: int = RunData.wishlist_hash_for_id(text)
		if item_hash == Keys.empty_hash:
			missing += 1
			continue

		hashes.push_back(item_hash)
		# 存档里的条目可能被游戏更新删掉了：hash 照样算得出来，但已经查不到对应 id
		if RunData.wishlist_id_for_hash(item_hash).empty():
			missing += 1

	RunData.set_wishlist(_character_id, hashes)
	# 读成功了才算「这一槽是最后使用的那一个」，绿框跟着走，并且记进存档。
	# 失败的那条路（空槽）上面已经 return 了，所以绿框不会因为手滑点空槽而跑掉。
	_active_slot = index
	RunData.set_wishlist_active_slot(_character_id, index)
	_refresh_slot_buttons()
	_refresh_all_hearts()

	var message := "已读取槽位 %d，共 %d 件" % [index + 1, hashes.size()]
	if missing > 0:
		message += "（其中 %d 件在当前版本里已找不到）" % missing
	_set_status(message)


func _on_DeleteButton_pressed() -> void:
	if not _is_slot_filled(_presets[_selected_slot]):
		_set_status("槽位 %d 本来就是空的" % (_selected_slot + 1))
		return

	# 删掉的正好是最后用的那一槽：那一槽都不存在了，记录也一起抹掉
	# （当前愿望单里的道具不动 —— 删槽只删存档，不影响手上这份）
	if _selected_slot == _active_slot:
		_active_slot = -1
		RunData.set_wishlist_active_slot(_character_id, -1)

	_presets[_selected_slot] = {}
	RunData.set_wishlist_slot(_character_id, _selected_slot, {})
	_select_slot(_selected_slot)
	_set_status("已清空槽位 %d" % (_selected_slot + 1))


# --- 交互 -----------------------------------------------------------------

func _on_element_pressed(element: InventoryElement) -> void:
	if element.item == null or element.is_special or element.item.is_locked:
		return

	RunData.toggle_wishlist_item(_character_id, _wishlist_key(element.item))
	_update_heart(element)
	_refresh_title()


# 悬停/聚焦到某个格子就把右侧卡片刷成它。
# 两个信号都接：鼠标只走 element_hovered，键盘/手柄只走 element_focused。
# 移开网格时不清空 —— 鼠标要移开网格才能去点旁边的按钮，清空反而闪。
func _on_element_hovered(element: InventoryElement) -> void:
	_update_card(element)


func _update_card(element: InventoryElement) -> void:
	if _description == null or element == null or element.item == null:
		return

	# 锁着的道具是当 special 格子画出来的，但 item 上仍然挂着真数据
	#（inventory.gd:71 的 add_special_element 把 element.item 一并传了），
	# 所以只看 item == null 会把解锁前的内容透出去，必须连 is_locked 一起判。图鉴也是这么判的。
	if element.is_special or element.item.is_locked:
		_description.set_custom_data("???", _inventory.locked_icon)
		# 标题行平时是藏着的（只显示属性），但锁着的条目全部内容就在标题行里，得放出来
		_set_card_header_visible(true)
	else:
		# player_index 固定 0：图鉴在选角/图鉴这类非局内场景传的也是 0
		_description.set_item(element.item, 0)
		_set_card_header_visible(false)


func _on_ClearButton_pressed() -> void:
	RunData.clear_wishlist(_character_id)
	# 绿框不动：它记的是「这个角色最后用的是哪一槽」这个事实，
	# 清空只是把手上这份清掉，槽位还在、上次用的是哪一槽也没变
	_refresh_all_hearts()
	_set_status("当前愿望单已清空（槽位不受影响）")


func _on_CloseButton_pressed() -> void:
	hide()


func _on_popup_hide() -> void:
	_resume_focus_emulators()
	emit_signal("wishlist_closed")


# --- 面板打开期间压制 FocusEmulator ------------------------------------------

# FocusEmulator 把 W/A/S/D/E 当成方向/确认键（project.godot 里 ui_up 的
# physical_scancode 是 87=W，ui_select 是 69=E，CoopService._copy_device_actions()
# 又给键盘生成了 ui_up_7 这类带设备后缀的副本，所以键盘玩家一样吃这套）：
# 打字打到一半，它就会把菜单焦点挪到别的按钮上，按回车还会顺手把那颗按钮按下去。
# 它 _input 里对没匹配上的事件还会 set_input_as_handled()，所以不能指望事件还能漏给输入框。
#
# 它自己的 _input 第一行就是 `if focused_control == null: return`，所以把 focused_control
# 置空就能让它彻底闭嘴 —— 原版对 bug 上报窗口用的是同一招
# （focus_emulator.gd 里那个 `or BugReporter.visible`）。
#
# 本面板挂在 difficulty_selection 的根节点下，那张场景里配的 focus base 只有
# Inventory 和 BackButton —— 面板里的控件一个都不在里面，
# emulator 既管不到它们，又仍然盯着背后的愿望单按钮。
# 所以干脆整个面板开着期间都停掉它。
# 怎么找 emulator：走官方的 Utils.get_focus_emulator(player_index)，
# 它内部就是 get_scene_node().get_node_or_null("FocusEmulator%s" % (player_index + 1))，
# 而这一屏的 FocusEmulator1 正是根节点的直接子节点（本面板也挂在根节点下），一问就到。
#
# ⚠️ 延迟一帧再停：点开面板时 grab_focus 会触发 gui_focus_changed，而 emulator 是在
# 那个信号里才把自己接到新焦点上的，同步停会被它紧接着重新接回去。

func _pause_focus_emulators() -> void:
	if not _paused_emulators.empty():
		return

	var found = _find_focus_emulators()
	for emulator in found:
		_paused_emulators.push_back([emulator, emulator.focused_control])
		emulator.focused_control = null


func _resume_focus_emulators() -> void:
	for entry in _paused_emulators:
		var emulator = entry[0]
		# 期间如果有别的控件拿到焦点，emulator 自己已经接上了，别拿旧值盖回去
		if is_instance_valid(emulator) and emulator.focused_control == null:
			emulator.focused_control = entry[1]
	_paused_emulators = []


# 每个玩家一个 emulator，按官方那套问过去（coop_end_run_player_container.gd、coop_shop.gd
# 也是这么循环问的）。拿来的是强类型引用，找不到返回 null，直接跳过。
#
# 原来是自己从 get_tree().root 往下扫、拿 node.get_class() == "FocusEmulator" 比，
# 两个毛病：
#   一是 get_class() 返回的是**原生类**，FocusEmulator 是脚本的 class_name，实际是 Node2D，
#      一个都对不上（判断要用 `is FocusEmulator`），等于这段逻辑一直在空转；
#   二是那样扫会把别的场景挂在树上的 emulator 一并停掉 —— 只停这一屏自己的才对。
func _find_focus_emulators() -> Array:
	# players_data 为空时（按钮本来就是灰的，正常打不开）也至少问一次 0 号。
	# 外层 int()：GDScript 3 的 max() 分析器上返回 float（同 _update_columns()）
	var player_count: int = int(max(1, RunData.get_player_count()))

	var found := []
	for player_index in range(player_count):
		var emulator = Utils.get_focus_emulator(player_index)
		if emulator != null:
			found.push_back(emulator)

	return found


# --- 槽位数据 --------------------------------------------------------------

# _ready() 时 _presets 还是空的，_refresh_slot_buttons() 会按下标读它，先垫一份全空的。
# 真正的槽位内容由 set_character() 从 RunData 取。
# 本文件不再读写存档 —— 存读档全在 RunData（extensions/singletons/run_data.gd）。
func _empty_presets() -> Array:
	var presets: Array = []
	for _i in range(SLOT_COUNT):
		presets.push_back({})
	return presets
