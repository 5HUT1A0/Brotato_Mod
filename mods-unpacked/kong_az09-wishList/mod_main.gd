extends Node

const MOD_DIR := "kong_az09-wishList"
const LOG_NAME := "wishList"

# 入口只有难度选择界面一处：
# 那一屏是所有角色开局前都要过的最后一屏，而选武器屏 bull 根本到不了
# （weapon_slot = 0 且没有初始道具，RunData.some_player_has_weapon_slots() 判 false，
# character_selection.gd:219-223 会整屏跳过）。
const EXTENSIONS := [
	"extensions/singletons/run_data.gd",
	"extensions/ui/menus/run/difficulty_selection/difficulty_selection.gd",
	"extensions/ui/menus/shop/shop_items_container.gd",
	"extensions/ui/menus/ingame/upgrades_ui_player_container.gd",
]


func _init() -> void :
	# 注意：不要写 _init(modLoader) 参数，6.1.0 起已废弃
	ModLoaderLog.info("mod 加载中", LOG_NAME)

	# 注册必须放在 _init 里，不能放 _ready()。
	#
	# ModLoader 是在自己的 _init 里 new() 出 mod_main 的（此时 is_initializing 仍为 true），
	# 我们在这一步调用，扩展只会**进队列**，随后由 mod_loader.gd:180 的
	# handle_script_extensions() 统一 apply_extension() —— 那时连 ModLoader 自己都还没进树。
	#
	# 放 _ready() 就晚了：Godot 先把所有 autoload 节点按顺序构造出来，_ready 统一推迟到后面触发。
	# 等 mod_main._ready 跑到时，RunData（第 14 个 autoload）早就拿着原版脚本实例化了，
	# take_over_path 救不回来 —— 表现就是
	# 「Invalid call. Nonexistent function 'is_wishlisted' in base 'Node (run_data.gd)'」。
	# 另外三个都是「进游戏才实例化的场景」的脚本（难度选择屏、商店、局内升级/开箱界面），
	# 晚装也能生效，所以只有 RunData 会出事。
	for extension in EXTENSIONS:
		ModLoaderMod.install_script_extension(
			"res://mods-unpacked/%s/%s" % [MOD_DIR, extension]
		)
