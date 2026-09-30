extends Node3D

const PORT = 8910
const PLAYER_SCENE = preload("res://scenes/player.tscn")

@onready var main_menu = $CanvasLayer/MainMenu
@onready var address_entry = $CanvasLayer/MainMenu/VBoxContainer/AddressEntry
@onready var key_display = $CanvasLayer/MainMenu/VBoxContainer/KeyDisplay
@onready var copy_key_button = $CanvasLayer/MainMenu/VBoxContainer/CopyKeyButton
@onready var status_label = $CanvasLayer/MainMenu/VBoxContainer/StatusLabel
@onready var host_button = $CanvasLayer/MainMenu/VBoxContainer/HostButton
@onready var join_button = $CanvasLayer/MainMenu/VBoxContainer/JoinButton
@onready var players_node = $Players

var room_key = ""

func _ready():
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	copy_key_button.pressed.connect(_on_copy_key_pressed)
	copy_key_button.hide()
	key_display.hide()

func _on_host_pressed():
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(PORT)
	if err != OK:
		status_label.text = " Ошибка создания сервера: " + str(err)
		return

	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(add_player)
	multiplayer.peer_disconnected.connect(remove_player)
	add_player(multiplayer.get_unique_id())

	var ext_ip = setup_upnp()
	room_key = ip_to_key(ext_ip)
	
	DisplayServer.clipboard_set(room_key)
	main_menu.hide()

func _on_join_pressed():
	var input_text = address_entry.text.strip_edges()
	if input_text == "":
		status_label.text = " Введите ключ комнаты или IP!"
		return

	var target_ip = key_to_ip(input_text)
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(target_ip, PORT)
	if err != OK:
		status_label.text = " Ошибка подключения: " + str(err)
		return

	multiplayer.multiplayer_peer = peer
	main_menu.hide()

func _on_copy_key_pressed():
	DisplayServer.clipboard_set(room_key)
	main_menu.hide()

func setup_upnp() -> String:
	var upnp = UPNP.new()
	var discover_result = upnp.discover()
	if discover_result == UPNP.UPNP_RESULT_SUCCESS:
		if upnp.get_gateway() and upnp.get_gateway().is_valid_gateway():
			var map_result = upnp.add_port_mapping(PORT, PORT, "Godot_FPS", "UDP")
			if map_result == UPNP.UPNP_RESULT_SUCCESS:
				return upnp.query_external_address()
	
	for ip in IP.get_local_addresses():
		if ip.find(".") != -1 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			return ip
	return "127.0.0.1"

func ip_to_key(ip: String) -> String:
	var parts = ip.split(".")
	if parts.size() != 4:
		return ip
	var h1 = "%02X" % parts[0].to_int()
	var h2 = "%02X" % parts[1].to_int()
	var h3 = "%02X" % parts[2].to_int()
	var h4 = "%02X" % parts[3].to_int()
	return "%s%s-%s%s" % [h1, h2, h3, h4]

func key_to_ip(key: String) -> String:
	var clean = key.strip_edges().to_upper().replace("-", "")
	if clean.length() == 8:
		var valid = true
		for c in clean:
			if not (c in "0123456789ABCDEF"):
				valid = false
				break
		if valid:
			var p1 = ("0x" + clean.substr(0, 2)).hex_to_int()
			var p2 = ("0x" + clean.substr(2, 2)).hex_to_int()
			var p3 = ("0x" + clean.substr(4, 2)).hex_to_int()
			var p4 = ("0x" + clean.substr(6, 2)).hex_to_int()
			return "%d.%d.%d.%d" % [p1, p2, p3, p4]
	return key

func add_player(peer_id):
	var player = PLAYER_SCENE.instantiate()
	player.name = str(peer_id)
	players_node.add_child(player)

func remove_player(peer_id):
	var player = players_node.get_node_or_null(str(peer_id))
	if player:
		player.queue_free()
