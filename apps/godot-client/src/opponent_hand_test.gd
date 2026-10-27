extends SceneTree

## Checks the opponent's hand is laid out as the player's own, mirrored.
##
## Needs no server:
##   godot --headless --path apps/godot-client --script src/opponent_hand_test.gd

const OpponentHand := preload("res://src/opponent_hand.gd")

var failures: Array[String] = []

func _init() -> void:
	await process_frame
	print("== opponent hand test ==")
	var hand := OpponentHand.new()
	get_root().add_child(hand)
	hand.size = Vector2(900, OpponentHand.HEIGHT)

	hand.set_counts(5, 20)
	var left: Array = hand.rest_of(0)
	var middle: Array = hand.rest_of(2)
	var right: Array = hand.rest_of(4)
	_check("the fan is centred", absf((middle[0] as Vector2).x - hand.size.x * 0.5) < 0.5)
	_check("the outer cards rise above the middle one",
		(left[0] as Vector2).y < (middle[0] as Vector2).y
			and is_equal_approx((left[0] as Vector2).y, (right[0] as Vector2).y))
	_check("the cards lean the other way to the player's",
		float(left[1]) > 0.0 and float(right[1]) < 0.0 and is_zero_approx(float(middle[1])))
	_check("the cards hang off the top, their foot in view",
		(middle[0] as Vector2).y - OpponentHand.CARD_SIZE.y * 0.5 < 0.0
			and (middle[0] as Vector2).y + OpponentHand.CARD_SIZE.y * 0.5 <= hand.size.y)
	_check("a small hand is held together",
		(right[0] as Vector2).x - (left[0] as Vector2).x < OpponentHand.CARD_SIZE.x * 4.0)
	_check("the counts are hidden until pointed at", not hand.is_showing_counts())
	_check("the empty strip beside the fan is not the fan",
		not hand.over_cards(Vector2(10, hand.size.y * 0.5)))
	hand._gui_input(_motion(Vector2(hand.size.x * 0.5, hand.size.y * 0.5)))
	_check("pointing at the cards shows the counts", hand.is_showing_counts())
	_check("the counts give the hand and the deck", hand.counts_text() == "Hand 5 · Deck 20")
	hand.notification(Control.NOTIFICATION_MOUSE_EXIT)
	_check("leaving the cards hides the counts", not hand.is_showing_counts())

	hand.set_counts(30, 0)
	var first: Array = hand.rest_of(0)
	var last: Array = hand.rest_of(29)
	_check("a full hand stays within its width",
		(first[0] as Vector2).x >= 0.0 and (last[0] as Vector2).x <= hand.size.x)

	hand.set_counts(0, 12)
	hand._gui_input(_motion(Vector2(hand.size.x * 0.5, hand.size.y * 0.5)))
	_check("an empty hand has nothing to point at", not hand.is_showing_counts())

	print("%d failure(s)" % failures.size())
	for failure in failures:
		print("  FAIL: ", failure)
	print("RESULT: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func _motion(at: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = at
	return event

func _check(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["ok" if condition else "XX", label])
	if not condition:
		failures.append(label)
