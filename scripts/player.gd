extends CharacterBody3D

const DROPPED_WEAPON_SCENE = preload("res://scenes/dropped_weapon.tscn")

@export var WALK_SPEED = 5.0
@export var SPRINT_SPEED = 9.0
@export var JUMP_VELOCITY = 4.5
@export var MOUSE_SENSITIVITY = 0.0025
@export var FIRE_RATE = 0.09
@export var MAX_HEALTH: float = 100.0

@export var health: float = 100.0
@export var has_weapon: bool = true

# Патроны и состояние
@export var ammo_in_mag: int = 32
@export var max_mag_ammo: int = 32
@export var reserve_ammo: int = 128
var is_reloading: bool = false
var is_sprinting: bool = false

@onready var head = $Head
@onready var camera = $Head/Camera3D
@onready var weapon_rig = $Head/Camera3D/WeaponRig
@onready var left_arm = $Head/Camera3D/WeaponRig/LeftArm
@onready var raycast = $Head/Camera3D/RayCast3D
@onready var muzzle_flash = $Head/Camera3D/WeaponRig/MuzzleFlash
@onready var smoke_particles = $Head/Camera3D/WeaponRig/SmokeParticles
@onready var shoot_sound = $Head/Camera3D/WeaponRig/ShootSound

@onready var visuals = $Visuals
@onready var left_leg = $Visuals/LeftLeg
@onready var right_leg = $Visuals/RightLeg
@onready var hud = $HUD
@onready var health_bar = $HUD/HealthBar
@onready var health_label = $HUD/HealthLabel
@onready var ammo_label = $HUD/AmmoLabel
@onready var interact_hint = $HUD/InteractHint

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var shoot_timer = 0.0

# Исходные трансформации
var default_weapon_pos = Vector3(0.22, -0.28, -0.45)
var default_left_arm_pos = Vector3.ZERO
var target_weapon_pos = Vector3.ZERO
var target_weapon_rot = Vector3.ZERO

# Тряска и углы прицеливания
var cam_pitch: float = 0.0
var mouse_mov = Vector2.ZERO
var bob_time: float = 0.0
var walk_anim_time: float = 0.0

var camera_bob_pos = Vector3.ZERO
var camera_bob_rot = Vector3.ZERO
var camera_shake_rot = Vector3.ZERO
var trauma: float = 0.0

func _enter_tree():
	set_multiplayer_authority(str(name).to_int())

func _ready():
	health = MAX_HEALTH
	if left_arm:
		default_left_arm_pos = left_arm.position

	if is_multiplayer_authority():
		camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if weapon_rig:
			weapon_rig.position = default_weapon_pos
			weapon_rig.visible = has_weapon
		visuals.visible = false
		hud.visible = true
		update_hud()
	else:
		camera.current = false
		visuals.visible = true
		hud.visible = false

func _unhandled_input(event):
	if not is_multiplayer_authority():
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		head.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		cam_pitch -= event.relative.y * MOUSE_SENSITIVITY
		cam_pitch = clamp(cam_pitch, deg_to_rad(-89), deg_to_rad(89))
		mouse_mov = event.relative

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _physics_process(delta):
	animate_body(delta)

	if not is_multiplayer_authority():
		return

	check_interact_hint()

	if Input.is_action_just_pressed("drop_weapon") and has_weapon and not is_reloading:
		drop_weapon_rpc.rpc()

	if Input.is_action_just_pressed("interact"):
		try_pickup_weapon()

	if Input.is_action_just_pressed("reload") and has_weapon and not is_reloading:
		start_reload()

	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		add_trauma(0.35)

	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction = (head.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	is_sprinting = Input.is_action_pressed("sprint") and is_on_floor() and input_dir.y < -0.1 and not is_reloading
	var speed = SPRINT_SPEED if is_sprinting else WALK_SPEED

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()

	# Расчёт динамической тряски камеры и оружия
	process_camera_and_sway(delta, input_dir)

	# Выстрелы
	if shoot_timer > 0:
		shoot_timer -= delta
	
	if Input.is_action_pressed("shoot") and shoot_timer <= 0 and has_weapon and not is_reloading:
		if ammo_in_mag > 0:
			shoot_rpc.rpc()
			shoot_timer = FIRE_RATE
		else:
			start_reload()

func process_camera_and_sway(delta, input_dir: Vector2):
	var speed_2d = Vector2(velocity.x, velocity.z).length()
	
	# 1. Тряска камеры при ходьбе и спринте
	if is_on_floor() and speed_2d > 0.2:
		var freq = 15.0 if is_sprinting else 9.5
		var amp_y = 0.065 if is_sprinting else 0.03
		var amp_x = 0.04 if is_sprinting else 0.018
		
		bob_time += delta * freq

		var target_bob_pos = Vector3(
			cos(bob_time * 0.5) * amp_x,
			sin(bob_time) * amp_y,
			0.0
		)
		camera_bob_pos = camera_bob_pos.lerp(target_bob_pos, delta * 12.0)

		# Поворотная тряска (Pitch / Roll) - ощущается намного сильнее
		var rot_pitch = sin(bob_time) * (0.025 if is_sprinting else 0.01)
		var rot_roll = cos(bob_time * 0.5) * (0.035 if is_sprinting else 0.015)
		rot_roll -= input_dir.x * (0.05 if is_sprinting else 0.025) # Крен при стрейфе
		
		camera_bob_rot = camera_bob_rot.lerp(Vector3(rot_pitch, 0, rot_roll), delta * 12.0)
	else:
		bob_time = 0.0
		camera_bob_pos = camera_bob_pos.lerp(Vector3.ZERO, delta * 10.0)
		camera_bob_rot = camera_bob_rot.lerp(Vector3.ZERO, delta * 10.0)

	# 2. Сотрясения при стрельбе и взрывах (Trauma Shake)
	if trauma > 0.0:
		trauma = max(trauma - delta * 2.2, 0.0)
		var shake = trauma * trauma
		camera_shake_rot = Vector3(
			randf_range(-1, 1) * 0.07 * shake,
			randf_range(-1, 1) * 0.06 * shake,
			randf_range(-1, 1) * 0.05 * shake
		)
	else:
		camera_shake_rot = Vector3.ZERO

	# Итоговая трансформация Камеры
	camera.position = camera_bob_pos
	camera.rotation = Vector3(cam_pitch, 0, 0) + camera_bob_rot + camera_shake_rot

	# Динамический FOV при беге
	var target_fov = 84.0 if is_sprinting else 75.0
	camera.fov = lerp(camera.fov, target_fov, delta * 8.0)

	# 3. Инерция и качание оружия (Weapon Sway & Sway Bob)
	target_weapon_pos = target_weapon_pos.lerp(Vector3.ZERO, delta * 12.0)
	target_weapon_rot = target_weapon_rot.lerp(Vector3.ZERO, delta * 12.0)

	var sway_rot = Vector3(
		deg_to_rad(-mouse_mov.y * 0.06),
		deg_to_rad(-mouse_mov.x * 0.06),
		deg_to_rad(mouse_mov.x * 0.04)
	)
	mouse_mov = mouse_mov.lerp(Vector2.ZERO, delta * 10.0)

	if weapon_rig and has_weapon and not is_reloading:
		var w_bob = Vector3(
			cos(bob_time * 0.5) * (0.02 if is_sprinting else 0.008),
			sin(bob_time) * (0.02 if is_sprinting else 0.008),
			0
		)
		weapon_rig.position = default_weapon_pos + target_weapon_pos + w_bob
		weapon_rig.rotation = target_weapon_rot + sway_rot

func add_trauma(amount: float):
	trauma = clamp(trauma + amount, 0.0, 1.0)

# Красивая перезарядка: левая рука работает непосредственно с моделью автомата
func start_reload():
	if is_reloading or ammo_in_mag == max_mag_ammo or reserve_ammo <= 0 or not has_weapon:
		return

	is_reloading = true
	var tween = create_tween().set_parallel(false)

	# 1. Повернуть MP40 приёмником к себе
	tween.tween_property(weapon_rig, "position", default_weapon_pos + Vector3(-0.04, 0.02, 0.08), 0.2)
	tween.parallel().tween_property(weapon_rig, "rotation", Vector3(deg_to_rad(-12), deg_to_rad(22), deg_to_rad(-15)), 0.2)
	
	# 2. Левая рука подносится к магазину MP40
	tween.parallel().tween_property(left_arm, "position", default_left_arm_pos + Vector3(0.02, 0.02, 0.05), 0.18)
	
	# 3. Левая рука "вытаскивает" пустой магазин вниз из ствола за экран
	tween.tween_property(left_arm, "position", default_left_arm_pos + Vector3(0.02, -0.55, 0.1), 0.22)
	
	# 4. Небольшая задержка (доставание нового магазина из подсумка)
	tween.tween_interval(0.1)
	
	# 5. Рука возвращается снизу и вставляет новый магазин в приёмник
	tween.tween_property(left_arm, "position", default_left_arm_pos + Vector3(0.02, 0.02, 0.05), 0.22)
	
	# 6. Хлёсткий хлопок ладонью по магазину + встряска
	tween.tween_callback(func(): add_trauma(0.2))
	tween.tween_property(weapon_rig, "position", default_weapon_pos + Vector3(-0.04, 0.04, 0.06), 0.06)
	
	# 7. Левая рука перемещается к рукоятке затвора (слева сверху) и дергает его назад
	tween.tween_property(left_arm, "position", default_left_arm_pos + Vector3(-0.14, 0.12, -0.15), 0.15)
	tween.tween_property(left_arm, "position", default_left_arm_pos + Vector3(-0.14, 0.12, -0.05), 0.1)
	
	# 8. Возврат оружия и рук в исходную стойку
	tween.tween_property(weapon_rig, "position", default_weapon_pos, 0.2)
	tween.parallel().tween_property(weapon_rig, "rotation", Vector3.ZERO, 0.2)
	tween.parallel().tween_property(left_arm, "position", default_left_arm_pos, 0.2)
	
	# Расчёт патронов
	tween.tween_callback(func():
		var needed = max_mag_ammo - ammo_in_mag
		var to_add = min(needed, reserve_ammo)
		ammo_in_mag += to_add
		reserve_ammo -= to_add
		is_reloading = false
		update_hud()
	)

func check_interact_hint():
	if raycast and raycast.is_colliding():
		var collider = raycast.get_collider()
		if collider and collider.is_in_group("dropped_weapons") and not has_weapon:
			var dist = global_position.distance_to(collider.global_position)
			if dist <= 3.5:
				interact_hint.visible = true
				return
	interact_hint.visible = false

func try_pickup_weapon():
	if raycast and raycast.is_colliding():
		var collider = raycast.get_collider()
		if collider and collider.is_in_group("dropped_weapons") and not has_weapon:
			var dist = global_position.distance_to(collider.global_position)
			if dist <= 3.5 and collider.has_method("pickup_rpc"):
				collider.pickup_rpc.rpc(get_path())

@rpc("call_local", "any_peer")
func drop_weapon_rpc():
	has_weapon = false
	if weapon_rig:
		weapon_rig.visible = false

	if is_multiplayer_authority():
		var dropped = DROPPED_WEAPON_SCENE.instantiate()
		var spawn_pos = camera.global_position + (-camera.global_transform.basis.z * 0.8)
		dropped.global_position = spawn_pos
		dropped.rotation = camera.global_rotation
		
		var items_container = get_tree().current_scene.get_node_or_null("DroppedItems")
		if items_container:
			items_container.add_child(dropped, true)
		else:
			get_parent().add_child(dropped, true)

		var throw_dir = -camera.global_transform.basis.z + Vector3(0, 0.2, 0)
		dropped.apply_central_impulse(throw_dir * 5.0)

	update_hud()

func equip_weapon():
	has_weapon = true
	if weapon_rig:
		weapon_rig.visible = true
	update_hud()

func animate_body(delta):
	if visuals:
		visuals.rotation.y = head.rotation.y
		var speed_2d = Vector2(velocity.x, velocity.z).length()
		if is_on_floor() and speed_2d > 0.1:
			walk_anim_time += delta * (18.0 if is_sprinting else 12.0)
			var leg_angle = sin(walk_anim_time) * deg_to_rad(40 if is_sprinting else 28)
			left_leg.rotation.x = leg_angle
			right_leg.rotation.x = -leg_angle
		else:
			walk_anim_time = 0.0
			left_leg.rotation.x = move_toward(left_leg.rotation.x, 0.0, delta * 8)
			right_leg.rotation.x = move_toward(right_leg.rotation.x, 0.0, delta * 8)

@rpc("call_local", "any_peer")
func shoot_rpc():
	if not has_weapon or ammo_in_mag <= 0:
		return

	ammo_in_mag -= 1
	update_hud()

	# Толчок автомата и сотрясение экрана
	target_weapon_pos += Vector3(0, 0.04, 0.16)
	target_weapon_rot += Vector3(deg_to_rad(8.5), deg_to_rad(randf_range(-3, 3)), deg_to_rad(randf_range(-2, 2)))
	
	# Импульс отдачи в камеру
	cam_pitch += deg_to_rad(0.4)
	add_trauma(0.32)

	if shoot_sound and shoot_sound.stream:
		shoot_sound.pitch_scale = randf_range(0.95, 1.05)
		shoot_sound.play()

	if muzzle_flash:
		muzzle_flash.visible = true
		get_tree().create_timer(0.04).timeout.connect(func(): muzzle_flash.visible = false)
	
	if smoke_particles:
		smoke_particles.restart()

	if is_multiplayer_authority() and raycast and raycast.is_colliding():
		var hit = raycast.get_collider()
		if hit and hit.has_method("take_damage_rpc"):
			hit.take_damage_rpc.rpc(20.0)

@rpc("call_local", "any_peer")
func take_damage_rpc(amount: float):
	health -= amount
	if health < 0:
		health = 0
	add_trauma(0.6)
	update_hud()
	
	if health <= 0 and is_multiplayer_authority():
		respawn()

func update_hud():
	if is_multiplayer_authority():
		if health_bar and health_label:
			health_bar.value = health
			health_label.text = "HP: " + str(int(health))
		if ammo_label:
			if has_weapon:
				ammo_label.text = "AMMO: " + str(ammo_in_mag) + " / " + str(reserve_ammo)
			else:
				ammo_label.text = "НЕТ ОРУЖИЯ"

func respawn():
	health = MAX_HEALTH
	ammo_in_mag = max_mag_ammo
	reserve_ammo = 128
	position = Vector3(randf_range(-4, 4), 1.0, randf_range(-12, 12))
	update_hud()
