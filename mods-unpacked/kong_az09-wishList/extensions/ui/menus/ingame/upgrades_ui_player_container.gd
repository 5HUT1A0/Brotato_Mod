extends "res://ui/menus/ingame/upgrades_ui_player_container.gd"

# 开箱（木箱、各种 item box 消耗品）时「拿取」键上的愿望单爱心。
#
# 为什么挂在容器这一层：
# 箱子里的东西最后都走到 upgrades_ui.gd:_show_next_player_options() → player_container.show_item()
# 这一句（额外掉落走 _get_extra_crate_item()，消耗品走 show_consumable_data()），
# 挂在容器上就不用管上面有几条路进来，而且拿得到 player_index（合作模式下每个容器管自己那个玩家）。
#
# 为什么不能照抄商店那套（shop_items_container.gd 的 _add_heart）：
# 商店的购买键是 ButtonWithIcon，内容是一个 HBoxContainer 子节点，爱心塞进内容最左，
# 靠 get_content_size_x() 把按钮撑宽。这里的 TakeButton 是个光板 Button
# （upgrades_ui_player_container.tscn:322 / coop_upgrades_ui_player_container.tscn:470），
# text 和 icon 都是 Button 自己画的，一个子节点都没有 —— 爱心只能自己定锚点贴上去。
#
# 本脚本、coop_upgrades_ui_player_container.gd、upgrades_ui.gd 都没把 self 传进带类型参数的位置，
# 所以扩展它是安全的，理由见 shop_items_container.gd 开头那段。
# coop_upgrades_ui_player_container.gd 是 `extends UpgradesUIPlayerContainer` 的，扩展本脚本会
# 连带把它重载（script_extension.gd:_reload_vanilla_child_classes_for），合作模式的容器因此也走
# 这份 show_item —— 它自己没覆写 show_item，不用另外挂一份；万一哪次没重载到，也只是合作模式没爱心。

const HEART_COLOR := Color(1.0, 0.45, 0.65)
const HEART_SIZE := 28.0
const HEART_NODE := "WishlistHeart"
const HEART_MARGIN_LEFT := 8.0

# 爱心染色靠材质，不靠 modulate：max_hp.png 是一颗绿心（HP 图标），
# 而 modulate 只能做乘法，绿 × 粉 ≈ 灰绿。这段和商店那份、面板那份是同一个，重复一份的理由见上面。
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

var _heart_material: ShaderMaterial    # 每次开箱都要挂爱心，材质只编一次
var _heart_texture: Texture            # 同上，爱心本体也只取一次


# 爱心本体（max_hp 那颗小绿心）走官方接口取：ItemService.stats 里 stat_max_hp 那条的小图标。
# 不写死 preload("res://items/stats/max_hp.png")：preload 是**解析期**的，
# 游戏更新哪天把图标挪个位置，整个脚本就编译不过 —— mod 跟着一起出事。
# 走这条路最差只是返回 null（那就少一颗心），mod 照样能跑。
func _get_heart_texture() -> Texture:
	if _heart_texture == null:
		_heart_texture = ItemService.get_stat_small_icon(Keys.stat_max_hp_hash)
	return _heart_texture


# 每显示一件箱子道具就重算一次爱心：该亮的挂上，上一件留下的摘掉。
# 局内改不了愿望单，所以不需要轮询，跟着 show_item 走就够。
func show_item(item_data: ItemParentData) -> void :
	.show_item(item_data)

	if _should_show_heart(item_data):
		_add_heart()
	else:
		_remove_heart()


func _should_show_heart(item_data) -> bool:
	if item_data == null:
		return false

	var item_hash: int = _wishlist_key(item_data)

	# 合作模式下每个容器管自己那个玩家（player_index 就是它自己的），单人恒为 0。
	# player_index 越界就退回玩家 0 那条路（和商店爱心同一个判定）。
	if player_index >= 0 and player_index < RunData.players_data.size():
		var character = RunData.get_player_character(player_index)
		if character != null:
			return RunData.is_wishlisted_for(character.my_id, item_hash)

	return RunData.is_wishlisted(item_hash)


# 道具记 my_id_hash，武器记家族 hash（weapon_id_hash）：
# 一个武器家族有 4 阶，各阶是独立资源，my_id 带阶数后缀 ——
# weapon_cacti_club_1/_2/_3/_4，而 weapon_id 四阶都是 weapon_cacti_club。
# 开箱目前只会开出道具（ItemService.process_item_box 走 TierData.ITEMS），
# 但 show_item 的签名是 ItemParentData，留着武器这一支免得以后改动踩坑。
# 这段和商店、面板里那两份是同一个，重复一份的理由见文件开头。
func _wishlist_key(data) -> int:
	if data is WeaponData:
		return data.get_weapon_id_hash()
	return data.get_my_id_hash()


func _make_heart_material() -> ShaderMaterial:
	if _heart_material != null:
		return _heart_material

	var shader: = Shader.new()
	shader.code = HEART_SHADER_CODE
	_heart_material = ShaderMaterial.new()
	_heart_material.shader = shader
	# 颜色以 HEART_COLOR 为准：着色器里那份默认值只是兜底
	_heart_material.set_shader_param("tint", HEART_COLOR)
	return _heart_material


func _add_heart() -> void :
	if _take_button == null or _take_button.get_node_or_null(HEART_NODE) != null:
		return

	# 取不到图标就不挂爱心（正常玩不会走到这儿，只有游戏改掉属性表才会）
	var texture: Texture = _get_heart_texture()
	if texture == null:
		return

	var heart: = TextureRect.new()
	heart.name = HEART_NODE
	heart.texture = texture
	heart.material = _make_heart_material()
	heart.expand = true
	heart.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	heart.rect_min_size = Vector2(HEART_SIZE, HEART_SIZE)
	heart.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 贴左上角、垂直居中：位置和商店爱心「挂在内容最左」对齐。
	# 这一屏的按钮图标本来就全长在左边（DiscardButton 的手柄 Y 提示 margin_left 就是 5），
	# 而按钮里的图标和文字是 Button 自己画、整体居中的，爱心贴边压不到它们。
	heart.anchor_left = 0.0
	heart.anchor_right = 0.0
	heart.anchor_top = 0.5
	heart.anchor_bottom = 0.5
	heart.margin_left = HEART_MARGIN_LEFT
	heart.margin_right = HEART_MARGIN_LEFT + HEART_SIZE
	heart.margin_top = - HEART_SIZE * 0.5
	heart.margin_bottom = HEART_SIZE * 0.5

	_take_button.add_child(heart)


func _remove_heart() -> void :
	if _take_button == null:
		return

	var heart = _take_button.get_node_or_null(HEART_NODE)
	if heart == null:
		return

	# 真摘掉，不是 hide()：下件道具进来时留着旧爱心会挡住新爱心（新旧状态还可能不一样）
	_take_button.remove_child(heart)
	heart.queue_free()
