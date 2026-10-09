extends "res://ui/menus/shop/shop_items_container.gd"

# 商店格子上的愿望单爱心。
#
# 为什么挂在这一层，而不是直接扩展 shop_item.gd：
# shop_item.gd 声明了 `class_name ShopItem`，而它自己第 178 行又把自己传进
# ItemService.get_chance_getting_caught(shop_item: ShopItem)（item_service.gd:988）。
# ModLoader 的 take_over_path 之后，扩展脚本和全局类 ShopItem 变成两个不同的 Script 对象，
# GDScript 3 的类型检查是纯指针比较，于是扩展一编译就报
# 「argument 1. The passed argument's type (ShopItem) doesn't match (ShopItem)」。
# 这是 extends + class_name + 自身传参 的结构性冲突，改不了，只能换个挂载点。
#
# 本脚本（以及 run_data.gd / difficulty_selection.gd）都没把 self 传进带类型参数的位置，
# 所以扩展它们是安全的。
#
# 爱心逻辑全部内联在这里，不抽到别的脚本：跨脚本调用要么得给那边的类起 class_name
# （mod 里的 class_name 在运行时不一定能解析到），要么得走 preload 常量调静态方法
# （本项目没有先例）。内联最省事也最不容易出岔子。

const HEART_COLOR := Color(1.0, 0.45, 0.65)
const HEART_SIZE := 28.0
const HEART_NODE := "WishlistHeart"

# 爱心染色靠材质，不靠 modulate：图标是一颗绿心（HP 图标），
# 而 modulate 只能做乘法，绿 × 粉 ≈ 灰绿 —— 就是之前那个「灰心」。
# 这段和 ui/wishlist_panel.gd 里那份是同一个，重复一份的理由见文件开头那段说明。
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

var _heart_material: ShaderMaterial # 每次刷新都要挂爱心，材质只编一次
var _heart_texture: Texture # 同上，爱心本体也只取一次


# 爱心本体（max_hp 那颗小绿心）走官方接口取：ItemService.stats 里 stat_max_hp 那条的小图标。
# 不写死 preload("res://items/stats/max_hp.png")：preload 是**解析期**的，
# 游戏更新哪天把图标挪个位置，整个脚本就编译不过 —— mod 跟着一起出事。
# 走这条路最差只是返回 null（那就少一颗心），mod 照样能跑。
func _get_heart_texture() -> Texture:
	if _heart_texture == null:
		_heart_texture = ItemService.get_stat_small_icon(Keys.stat_max_hp_hash)
	return _heart_texture


func set_shop_items(items_data: Array) -> void:
	.set_shop_items(items_data)
	_refresh_hearts()


func reload_shop_items() -> void:
	.reload_shop_items()
	_refresh_hearts()


# 每次商店刷新、重掷、锁定变化后都把 4 个格子的爱心状态对齐一次。
# 愿望单只在选角界面能改，局内不会变，所以不需要每帧轮询。
func _refresh_hearts() -> void:
	if _shop_items == null:
		return

	for shop_item in _shop_items:
		if _should_show_heart(shop_item):
			_add_heart(shop_item)
		else:
			_remove_heart(shop_item)


func _should_show_heart(shop_item) -> bool:
	if shop_item == null:
		return false

	# 这一轮刷出的道具不足 4 个时，空槽位会被 deactivate()，不许挂爱心
	if not shop_item.active:
		return false

	var data = shop_item.item_data
	if data == null:
		return false

	return RunData.is_wishlisted(_wishlist_key(data))


# 道具记 my_id_hash，武器记家族 hash（weapon_id_hash）：
# 一个武器家族有 4 阶，各阶是独立资源，my_id 带阶数后缀 ——
# weapon_cacti_club_1/_2/_3/_4，而 weapon_id 四阶都是 weapon_cacti_club。
# 商店可能卖任意一阶，按 my_id_hash 记的话勾了 1 阶、卖 2 阶时爱心就不亮了。
# 这段和 ui/wishlist_panel.gd 里那份是同一个，重复一份的理由见文件开头那段说明。
# 两个 hash 都从官方 getter 取：武器必须走 get_weapon_id_hash（裸字段 weapon_id_hash 是 onready 的，
# 没生成过就是 empty_hash），道具的 get_my_id_hash 同理会兜底重算。
func _wishlist_key(data) -> int:
	if data is WeaponData:
		return data.get_weapon_id_hash()
	return data.get_my_id_hash()


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


func _add_heart(shop_item) -> void:
	var content = _get_button_content(shop_item)
	if content == null or content.get_node_or_null(HEART_NODE) != null:
		return

	# 取不到图标就不挂爱心（正常玩不会走到这儿，只有游戏改掉属性表才会）
	var texture: Texture = _get_heart_texture()
	if texture == null:
		return

	var heart := TextureRect.new()
	heart.name = HEART_NODE
	heart.texture = texture
	heart.material = _make_heart_material()
	heart.expand = true
	heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	heart.rect_min_size = Vector2(HEART_SIZE, HEART_SIZE)
	heart.mouse_filter = Control.MOUSE_FILTER_IGNORE


	# 塞进购买键内容的最左。ButtonWithIcon.get_content_size_x() 会把 HBoxContainer
	# 所有子节点的宽度加起来，_process 里据此调按钮宽度，所以按钮会自己变宽。
	content.add_child(heart)
	content.move_child(heart, 0)


func _remove_heart(shop_item) -> void:
	var content = _get_button_content(shop_item)
	if content == null:
		return

	var heart = content.get_node_or_null(HEART_NODE)
	if heart == null:
		return

	# 必须真的摘掉，不能只是 hide()：HBoxContainer 不给隐藏子节点排版，
	# 它的 rect_size 会停在旧值，get_content_size_x() 仍然把宽度算进去。
	content.remove_child(heart)
	heart.queue_free()


# 返回购买键的内容容器（HBoxContainer）；拿不到就返回 null
func _get_button_content(shop_item):
	var button = shop_item._button
	if button == null:
		return null

	# ButtonWithIcon 自己就是拿 _content 引用这个 HBoxContainer 的
	# （button_with_icon.gd 的 onready var _content = $HBoxContainer），
	# 优先问它：哪天原版把这个节点挪到别处，引用还在，写死的节点名就找不到了。
	# get() 问不到属性只会返回 null，不会报错，问不到再退回按名字找。
	var content = button.get("_content")
	if content != null:
		return content
	return button.get_node_or_null("HBoxContainer")
