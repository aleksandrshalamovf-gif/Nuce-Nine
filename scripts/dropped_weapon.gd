extends RigidBody3D

@rpc("call_local", "any_peer")
func pickup_rpc(player_path: NodePath):
	var player = get_node_or_null(player_path)
	if player and player.has_method("equip_weapon"):
		player.equip_weapon()
		queue_free()
