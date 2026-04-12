#+feature dynamic-literals
package main

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	lane_count := 2 //os.get_processor_core_count()
	g := new(G)
	// g.debugger_enabled = true
	g.busses = make(map[BusName]^Bus)
	bootstrap_barrier: sync.Barrier
	sync.barrier_init(&bootstrap_barrier, lane_count)

	temp_tls: TLS
	temp_tls.g = g
	temp_tls.lane_count = lane_count
	temp_tls.barrier = &bootstrap_barrier


	for i in 1 ..< lane_count {
		temp_tls.lane_id = i
		temp_tls.barrier = &bootstrap_barrier
		thread.create_and_start_with_poly_data(
			temp_tls,
			multithread_entry_point,
			self_cleanup = true,
			init_context = context,
		)
	}


	temp_tls.lane_id = 0 //lane id 0 is always main thread

	multithread_entry_point(temp_tls)

}

multithread_entry_point :: proc(tls_context: TLS) {
	tls = tls_context
	g := tls.g
	defer lane_sync()

	if is_main_thread() {
		//initialize SDL3
		success := sdl3.Init({.VIDEO, .EVENTS})
		ensure(success)
		g.window = sdl3.CreateWindow("Minimal 64x4", 640, 480, {})
		ensure(g.window != nil)
		g.renderer = sdl3.CreateRenderer(g.window, nil)
		ensure(g.renderer != nil)
		g.texture = sdl3.CreateTexture(g.renderer, .RGBA8888, .STREAMING, VGA_WIDTH, VGA_HEIGHT)
		ensure(g.texture != nil)

		microui.init(&g.microui_context)
		g.microui_context.text_height = microui.default_atlas_text_height
		g.microui_context.text_width = microui.default_atlas_text_width
		init_microui_atlas()
	}

	if is_simulator_thread() {
		build_the_computer()
	}


	last_frame: sdl3.Time
	ensure(sdl3.GetCurrentTime(&last_frame))

	next_vga_tick := 0
	next_system_tick := 0

	for !g.should_quit {
		free_all(context.temp_allocator)
		now: sdl3.Time
		assert(sdl3.GetCurrentTime(&now))
		dt := now - last_frame
		last_frame = now
		if is_main_thread() {
			e: sdl3.Event
			for sdl3.PollEvent(&e) {
				#partial switch e.type {
				case .QUIT:
					g.should_quit = true
				case .MOUSE_BUTTON_DOWN:
					switch e.button.button {
					case sdl3.BUTTON_LEFT:
						microui.input_mouse_down(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							.LEFT,
						)
					case sdl3.BUTTON_RIGHT:
						microui.input_mouse_down(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							.RIGHT,
						)
					case sdl3.BUTTON_MIDDLE:
						microui.input_mouse_down(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							.MIDDLE,
						)

					}
				case .MOUSE_BUTTON_UP:
					switch e.button.button {
					case sdl3.BUTTON_LEFT:
						microui.input_mouse_up(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							.LEFT,
						)
					case sdl3.BUTTON_RIGHT:
						microui.input_mouse_up(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							.RIGHT,
						)
					case sdl3.BUTTON_MIDDLE:
						microui.input_mouse_up(
							&g.microui_context,
							auto_cast e.button.x,
							auto_cast e.button.y,
							.MIDDLE,
						)
					}
				case .MOUSE_MOTION:
					microui.input_mouse_move(
						&g.microui_context,
						auto_cast e.motion.x,
						auto_cast e.motion.y,
					)
				}
			}

		}
		lane_sync()
		if is_simulator_thread() && !g.debugger_enabled {
			log.infof("dt: %v", dt)

			TARGET_FRAME_TIME :: 16_666_666
			SYSTEM_CLOCK_TICK_TIME_NS :: 1_000_000_000 / 16_000_000
			VGA_TICK_TIME_NS :: 1_000_000_000 / 25_175_000


			//update system
			assert(sdl3.GetCurrentTime(&now))

			tick_time := 0
			for !g.frame_complete {
				if next_vga_tick <= 0 {
					tick_vga_clock()
					next_vga_tick += VGA_TICK_TIME_NS
				}
				if next_system_tick <= 0 {
					tick_system_clock()
					next_system_tick += SYSTEM_CLOCK_TICK_TIME_NS
				}
				next_vga_tick -= VGA_TICK_TIME_NS
				next_system_tick -= VGA_TICK_TIME_NS
				tick_time += SYSTEM_CLOCK_TICK_TIME_NS
			}
			g.frame_complete = false
			tmp := now
			assert(sdl3.GetCurrentTime(&now))
			log.infof("time taken: %vns", now - tmp)

		}
		lane_sync()

		if is_main_thread() {
			mu_ctx := &g.microui_context
			microui.begin(mu_ctx)
			microui.begin_window(mu_ctx, "Debugger", microui.Rect{0, 0, 600, 400}, {.NO_CLOSE})
			frame_time_text := fmt.tprintf("Frame Time %vms", dt / 1000 / 1000)
			microui.text(mu_ctx, frame_time_text)

			if .ACTIVE in microui.begin_treenode(mu_ctx, "Chips") {
				b: strings.Builder
				strings.builder_init(&b, context.temp_allocator)
				for chip in g.chips {
					fmt.sbprintf(&b, "%s -- ", chip.type)
					for name, pin in chip.pins {
						fmt.sbprintf(&b, "%s: %s,", name, pin.value)
					}
					microui.layout_row(mu_ctx, {-1})
					microui.text(mu_ctx, strings.to_string(b))
					strings.builder_reset(&b)

				}
				microui.end_treenode(mu_ctx)
			}
			if .ACTIVE in microui.begin_treenode(mu_ctx, "Busses") {
				b: strings.Builder
				strings.builder_init(&b, context.temp_allocator)
				for bus_name, bus in g.busses {
					fmt.sbprintf(&b, "%s -- ", bus_name)
					for pin in bus.pins {
						fmt.sbprintf(&b, "%s: %s,", pin.name, pin.value)
					}
					microui.layout_row(mu_ctx, {-1})
					microui.text(mu_ctx, strings.to_string(b))
					strings.builder_reset(&b)

				}
				microui.end_treenode(mu_ctx)
			}
			microui.checkbox(mu_ctx, "Enable Debugger", &g.debugger_enabled)
			opt := microui.Options{.ALIGN_CENTER}
			if !g.debugger_enabled {
				opt |= {.NO_INTERACT}
			}
			if .SUBMIT in microui.button(mu_ctx, "Step", opt = opt) {
				tick_system_clock()
			}

			microui.end_window(mu_ctx)
			microui.end(mu_ctx)

		}

		if is_main_thread() {
			viewport := sdl3.Rect{144, 35, SCREEN_WIDTH, SCREEN_HEIGHT}
			viewport_f := sdl3.FRect{144, 35, SCREEN_WIDTH, SCREEN_HEIGHT}
			sdl3.RenderClear(g.renderer)

			raw_pixels: [^]Pixel
			pitch: c.int
			assert(sdl3.LockTexture(g.texture, &viewport, auto_cast &raw_pixels, &pitch))
			pixels := raw_pixels[0:(pitch / 4) * SCREEN_HEIGHT]
			copy(pixels, g.vga_display.vga_pixels)
			sdl3.UnlockTexture(g.texture)

			sdl3.RenderTexture(g.renderer, g.texture, &viewport_f, nil)

			cmd: ^microui.Command
			for microui.next_command(&g.microui_context, &cmd) {
				switch v in cmd.variant {
				case ^microui.Command_Text:
					render_text(v.font, v.str, v.pos.x, v.pos.y, v.color)
				case ^microui.Command_Clip:
					mu_rect := v.rect
					sdl_rect := sdl3.Rect{mu_rect.x, mu_rect.y, mu_rect.w, mu_rect.h}
					assert(sdl3.SetRenderClipRect(g.renderer, &sdl_rect))
				case ^microui.Command_Rect:
					mu_rect := v.rect
					sdl_rect := sdl3.FRect {
						auto_cast mu_rect.x,
						auto_cast mu_rect.y,
						auto_cast mu_rect.w,
						auto_cast mu_rect.h,
					}
					color := v.color
					sdl3.SetRenderDrawColor(g.renderer, color.r, color.g, color.b, color.a)
					sdl3.RenderFillRect(g.renderer, &sdl_rect)
				case ^microui.Command_Icon:
					render_icon(v.id, v.rect, v.color)
				case ^microui.Command_Jump:
				//do nothing?
				}
			}

			sdl3.RenderPresent(g.renderer)
			//Render screen
			//TODO
		}
	}
}
tick_vga_clock :: proc() {
	g := tls.g
	vga_clock_pin := g.vga_display.pins[.VGAClock]
	on_rising_edge(vga_clock_pin, nil)
}
tick_system_clock :: proc() {
	g := tls.g
	system_clock_pin := g.system_clock.pins[.MHZ16]
	system_clock_pin.value = .Hi //if system_clock_pin.value == .Low else .Low
	updated_pins: [dynamic]^Pin
	updated_pins.allocator = context.temp_allocator

	append(&updated_pins, system_clock_pin)
	for len(updated_pins) > 0 {
		pin_being_updated := pop_front(&updated_pins)
		new_value := pin_being_updated.value
		bus_being_updated := pin_being_updated.bus
		if bus_being_updated != nil {
			for pin in bus_being_updated.pins {
				//make sure we don't accidentally we try to update pin we got the change from
				if pin == pin_being_updated {
					continue
				}
				//TODO: dont think we need this because of how update_pin() works, but keep around just in case...
				// update_chip := pin.value != new_value || bus_being_updated == system_clock_pin.bus
				// if update_chip {
				pin.value = new_value
				switch new_value {
				case .Hi:
					on_rising_edge(pin, &updated_pins)
				case .Low:
					on_falling_edge(pin, &updated_pins)
				case .X:
				//high impedence, do nothing
				}
				// }
			}
		}
	}

}

on_rising_edge :: proc(pin: ^Pin, updated_pins: ^[dynamic]^Pin) {


	chip := pin.chip

	switch pin.chip.type {
	case .FourBitCounter:
		//We only care about CP, Q0, Q1, and Q2 in this
		//computer, so we don't need to consider any other pins
		if pin.name == .CP {
			chip.fbc_counter += 1
			chip.fbc_counter &= 0xF
			u4_to_pins(chip.fbc_counter, {.Q0, .Q1, .Q2, .Q3}, updated_pins, chip)
		}
	case .SixteenBitCounter:
		if pin.name == .CPC {
			chip.sbc_counter += 1
			if chip.pins[.nMRC].value == .Low {
				chip.sbc_counter = 0
			}

			u16_to_pins(
				chip.sbc_counter,
				{
					.Q0,
					.Q1,
					.Q2,
					.Q3,
					.Q4,
					.Q5,
					.Q6,
					.Q7,
					.Q8,
					.Q9,
					.Q10,
					.Q11,
					.Q12,
					.Q13,
					.Q14,
					.Q15,
				},
				updated_pins,
				chip,
			)
		}


	case .EightBitShiftRegister:
		if pin.name == .CP {
			chip.ebsr_register <<= 1
			if chip.pins[.nPE].value == .Low {
				chip.ebsr_register = pins_to_u8({.D0, .D1, .D2, .D3, .D4, .D5, .D6, .D7}, chip)
			}
			update_pin(
				.Hi if (chip.ebsr_register & 0x80) != 0 else .Low,
				chip.pins[.Q7],
				updated_pins,
			)
		}

	case .NORGate:
		a := chip.pins[.A]
		b := chip.pins[.B]
		y := chip.pins[.Y]
		result := !(a.value == .Hi || b.value == .Hi)
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .ORGate:
		a := chip.pins[.A]
		b := chip.pins[.B]
		y := chip.pins[.Y]
		result := a.value == .Hi || b.value == .Hi
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .ORGate3Input:
		a := chip.pins[.A]
		b := chip.pins[.B]
		c := chip.pins[.C]
		y := chip.pins[.Y]
		result := a.value == .Hi || b.value == .Hi || c.value == .Hi
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .NANDGate:
		a := chip.pins[.A]
		b := chip.pins[.B]
		y := chip.pins[.Y]
		result := !(a.value == .Hi && b.value == .Hi)
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)

	case .VGADisplay:
		if pin.name == .VGAClock {
			nhsync := chip.pins[.nHSYNC]
			nvsync := chip.pins[.nVSYNC]
			if nhsync.value != .Low && nvsync.value != .Low {
				if chip.vga_column < VGA_WIDTH {
					chip.vga_column += 1
				}
				rgb_pin := chip.pins[.RGB]
				color_value: u32 = 0xFFFF_FFFF if rgb_pin.value == .Hi else 0
				log.debugf(
					"x: %v, y: %v, Color %X, Shift register state: %X",
					chip.vga_column,
					chip.vga_row,
					color_value,
					rgb_pin.bus.pins[0].chip.ebsr_register,
				)
				chip.vga_pixels[chip.vga_row * VGA_WIDTH + chip.vga_column] = color_value
			}
		}
	case .SystemClock:
	//System clock is handled directly in the main loop
	case .FlipFlop:
	//Flip Flop is only affected by low signals

	}
}

on_falling_edge :: proc(pin: ^Pin, updated_pins: ^[dynamic]^Pin) {
	//TODO handle logic gates
	chip := pin.chip
	g := tls.g
	switch pin.chip.type {
	case .ORGate:
		a := chip.pins[.A]
		b := chip.pins[.B]
		y := chip.pins[.Y]
		result := a.value == .Hi || b.value == .Hi
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .NORGate:
		a := chip.pins[.A]
		b := chip.pins[.B]
		y := chip.pins[.Y]
		result := !(a.value == .Hi || b.value == .Hi)
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .ORGate3Input:
		a := chip.pins[.A]
		b := chip.pins[.B]
		c := chip.pins[.C]
		y := chip.pins[.Y]
		result := a.value == .Hi || b.value == .Hi || c.value == .Hi
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .NANDGate:
		a := chip.pins[.A]
		b := chip.pins[.B]
		y := chip.pins[.Y]
		result := !(a.value == .Hi && b.value == .Hi)
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .FlipFlop:
		ns := chip.pins[.nS]
		nr := chip.pins[.nR]
		q := chip.pins[.Q]

		if pin.name == .nS {
			update_pin(.Hi, q, updated_pins)
		} else if pin.name == .nR {
			update_pin(.Low, q, updated_pins)
		}

	case .SystemClock:
	//System clock is handled directly in the main loop
	//only updates on rising edge
	case .FourBitCounter:
	case .SixteenBitCounter:
	case .EightBitShiftRegister:
	case .VGADisplay:
		if pin.name == .nHSYNC {
			chip.vga_column = 0
			chip.vga_row += 1
		} else if pin.name == .nVSYNC {
			chip.vga_column = 0
			chip.vga_row = 0
			g.frame_complete = true
		}
	}

}

update_pin :: proc(new_value: PinValue, pin: ^Pin, updated_pins: ^[dynamic]^Pin) {
	if new_value != pin.value {
		pin.value = new_value
		append(updated_pins, pin)
	}
}

build_the_computer :: proc() {

	create_bus :: proc(name: BusName) -> ^Bus {
		g := tls.g
		result := new_clone(Bus{nil, name})
		g.busses[name] = result
		return result
	}

	g := tls.g
	chips: [dynamic]^Chip
	//System clock
	MHZ16_bus := create_bus(.MHZ16)
	system_clock_pin: ^Pin
	{
		g.system_clock = new_clone(Chip{type = .SystemClock, pins = make(map[PinName]^Pin)})
		g.system_clock.pins[.MHZ16] = new_clone(Pin{g.system_clock, MHZ16_bus, .MHZ16, .Low})
		system_clock_pin = g.system_clock.pins[.MHZ16]
		append(&chips, g.system_clock)
	}

	//Four bit counter
	MHZ8_bus := create_bus(.MHZ8)
	MHZ4_bus := create_bus(.MHZ4)
	MHZ2_bus := create_bus(.MHZ2)

	{
		four_bit_counter := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, four_bit_counter)
		four_bit_counter.type = .FourBitCounter
		//All data pins are tied high, so counter starts off at 0xF
		//(actually it should start at 0 and then jump to 0xF on the 2nd cycle, but this should be okay, hopefully...)
		four_bit_counter.fbc_counter = 0xF
		four_bit_counter.pins = {
			.CP = new_clone(Pin{four_bit_counter, MHZ16_bus, .CP, system_clock_pin.value}),
			.Q0 = new_clone(Pin{four_bit_counter, MHZ8_bus, .Q0, .Hi}),
			.Q1 = new_clone(Pin{four_bit_counter, MHZ4_bus, .Q1, .Hi}),
			.Q2 = new_clone(Pin{four_bit_counter, MHZ2_bus, .Q2, .Hi}),
			.Q3 = new_clone(Pin{four_bit_counter, nil, .Q3, .Hi}), //Q3 is not connected to anything, but here consistency

			//Don't care about any other pins on the four bit counter since theyre all tied high
		}
	}
	//nVREG_OE NOR gate
	nVREG_OE_bus := create_bus(.nVREG_OE)
	{
		nVREG_OE_NOR_gate := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, nVREG_OE_NOR_gate)
		nVREG_OE_NOR_gate.type = .NORGate
		nVREG_OE_NOR_gate.pins = {
			.A = new_clone(Pin{nVREG_OE_NOR_gate, MHZ4_bus, .A, .Low}),
			.B = new_clone(Pin{nVREG_OE_NOR_gate, MHZ2_bus, .B, .Low}),
			.Y = new_clone(Pin{nVREG_OE_NOR_gate, nVREG_OE_bus, .Y, .Hi}),
		}
	}

	//nVGA_GET NAND gate
	nVREG_GET_bus := create_bus(.nVGA_GET)
	{
		nVREG_GET_NAND_gate := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, nVREG_GET_NAND_gate)
		nVREG_GET_NAND_gate.type = .NANDGate
		nVREG_GET_NAND_gate.pins = {
			.A = new_clone(Pin{nVREG_GET_NAND_gate, MHZ8_bus, .A, .Low}),
			.B = new_clone(Pin{nVREG_GET_NAND_gate, nVREG_OE_bus, .B, .Low}),
			.Y = new_clone(Pin{nVREG_GET_NAND_gate, nVREG_GET_bus, .Y, .Hi}),
		}
	}

	//8-bit shift register for VGA output
	vga_rgb_bus := create_bus(.VGA_RGB)
	{
		vga_shift_register := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, vga_shift_register)
		vga_shift_register.type = .EightBitShiftRegister

		vga_shift_register.pins = {
			//TODO D0-D7 should be conntect to VRAM, but we will hard code a checker-board pattern (00110011) for now
			.D0  = new_clone(Pin{vga_shift_register, nil, .D0, .Low}),
			.D1  = new_clone(Pin{vga_shift_register, nil, .D1, .Low}),
			.D2  = new_clone(Pin{vga_shift_register, nil, .D2, .Hi}),
			.D3  = new_clone(Pin{vga_shift_register, nil, .D3, .Hi}),
			.D4  = new_clone(Pin{vga_shift_register, nil, .D4, .Low}),
			.D5  = new_clone(Pin{vga_shift_register, nil, .D5, .Low}),
			.D6  = new_clone(Pin{vga_shift_register, nil, .D6, .Hi}),
			.D7  = new_clone(Pin{vga_shift_register, nil, .D7, .Hi}),
			.CP  = new_clone(Pin{vga_shift_register, MHZ16_bus, .CP, .Low}),
			.nPE = new_clone(Pin{vga_shift_register, nVREG_GET_bus, .nPE, .Low}),
			.Q7  = new_clone(Pin{vga_shift_register, vga_rgb_bus, .Q7, .Low}), //controls the actual pixel color
		}
	}
	//VGA sync counter

	h1_bus := create_bus(.H1)
	h2_bus := create_bus(.H2)
	h4_bus := create_bus(.H4)
	h8_bus := create_bus(.H8)
	h16_bus := create_bus(.H16)
	h32_bus := create_bus(.H32)
	v1_bus := create_bus(.V1)
	v2_bus := create_bus(.V2)
	v4_bus := create_bus(.V4)
	v8_bus := create_bus(.V8)
	v16_bus := create_bus(.V16)
	v32_bus := create_bus(.V32)
	v64_bus := create_bus(.V64)
	v128_bus := create_bus(.V128)
	v256_bus := create_bus(.V256)

	nMRC_bus := create_bus(.nMRC)
	{
		vga_sync_counter := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, vga_sync_counter)
		vga_sync_counter.type = .SixteenBitCounter
		vga_sync_counter.pins = {
			.Q0   = new_clone(Pin{vga_sync_counter, h1_bus, .Q0, .Low}),
			.Q1   = new_clone(Pin{vga_sync_counter, h2_bus, .Q1, .Low}),
			.Q2   = new_clone(Pin{vga_sync_counter, h4_bus, .Q2, .Low}),
			.Q3   = new_clone(Pin{vga_sync_counter, h8_bus, .Q3, .Low}),
			.Q4   = new_clone(Pin{vga_sync_counter, h16_bus, .Q4, .Low}),
			.Q5   = new_clone(Pin{vga_sync_counter, h32_bus, .Q5, .Low}),
			//Q6 not connected
			.Q6   = new_clone(Pin{vga_sync_counter, nil, .Q6, .Low}),
			.Q7   = new_clone(Pin{vga_sync_counter, v1_bus, .Q7, .Low}),
			.Q8   = new_clone(Pin{vga_sync_counter, v2_bus, .Q8, .Low}),
			.Q9   = new_clone(Pin{vga_sync_counter, v4_bus, .Q9, .Low}),
			.Q10  = new_clone(Pin{vga_sync_counter, v8_bus, .Q10, .Low}),
			.Q11  = new_clone(Pin{vga_sync_counter, v16_bus, .Q11, .Low}),
			.Q12  = new_clone(Pin{vga_sync_counter, v32_bus, .Q12, .Low}),
			.Q13  = new_clone(Pin{vga_sync_counter, v64_bus, .Q13, .Low}),
			.Q14  = new_clone(Pin{vga_sync_counter, v128_bus, .Q14, .Low}),
			.Q15  = new_clone(Pin{vga_sync_counter, v256_bus, .Q15, .Low}),
			.CPC  = new_clone(Pin{vga_sync_counter, nVREG_GET_bus, .CPC, .Low}),
			.nMRC = new_clone(Pin{vga_sync_counter, nMRC_bus, .nMRC, .Hi}),
		}

	}

	hsync_bus := create_bus(.nHSYNC)
	{
		or_gate := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, or_gate)
		or_gate.type = .ORGate3Input
		or_gate.pins = {
			.A = new_clone(Pin{or_gate, h8_bus, .A, .Low}),
			.B = new_clone(Pin{or_gate, h16_bus, .B, .Low}),
			.C = new_clone(Pin{or_gate, h32_bus, .C, .Low}),
			.Y = new_clone(Pin{or_gate, hsync_bus, .Y, .Low}),
		}

	}

	{
		nand_gate := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, nand_gate)
		nand_gate.type = .NANDGate
		nand_gate.pins = {
			.A = new_clone(Pin{nand_gate, v4_bus, .A, .Low}),
			.B = new_clone(Pin{nand_gate, v256_bus, .B, .Low}),
			.Y = new_clone(Pin{nand_gate, nMRC_bus, .Y, .Hi}),
		}
	}


	vga_flip_flop_set_bus := create_bus(.VGAFlipFlopSet)
	{
		nand_gate := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, nand_gate)
		nand_gate.type = .NANDGate
		nand_gate.pins = {
			.A = new_clone(Pin{nand_gate, v1_bus, .A, .Low}),
			.B = new_clone(Pin{nand_gate, nil, .B, .Hi}),
			.Y = new_clone(Pin{nand_gate, vga_flip_flop_set_bus, .Y, .Hi}),
		}
	}

	vsync_bus := create_bus(.nVSYNC)
	{
		flip_flop := new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, flip_flop)
		flip_flop.type = .FlipFlop
		flip_flop.pins = {
			.nS = new_clone(Pin{flip_flop, vga_flip_flop_set_bus, .nS, .Hi}),
			.nR = new_clone(Pin{flip_flop, nMRC_bus, .nR, .Hi}),
			.Q  = new_clone(Pin{flip_flop, vsync_bus, .Q, .Low}),
		}
	}

	{
		g.vga_display = new_clone(Chip{pins = make(map[PinName]^Pin)})
		append(&chips, g.vga_display)
		g.vga_display.type = .VGADisplay
		g.vga_display.pins = {
			.RGB      = new_clone(Pin{g.vga_display, vga_rgb_bus, .RGB, .Low}),
			.VGAClock = new_clone(Pin{g.vga_display, nil, .VGAClock, .Hi}),
			.nHSYNC   = new_clone(Pin{g.vga_display, hsync_bus, .nHSYNC, .Low}),
			.nVSYNC   = new_clone(Pin{g.vga_display, vsync_bus, .nVSYNC, .Low}),
		}
		g.vga_display.vga_pixels = make([]Pixel, VGA_WIDTH * VGA_HEIGHT)

	}

	//TODO build rest of chips


	g.chips = chips[:]
	for chip in chips {
		for _, &pin in chip.pins {
			if pin.bus != nil {
				append(&pin.bus.pins, pin)
			}
		}
	}

}

pins_to_u8 :: proc(pin_names: [8]PinName, chip: ^Chip) -> u8 {
	result: u8
	for pin_name, index in pin_names {
		pin := chip.pins[pin_name]
		if pin.value == .Hi {
			result |= 1 << auto_cast index
		}
	}
	return result
}

u8_to_pins :: proc(value: u8, pin_names: [8]PinName, updated_pins: ^[dynamic]^Pin, chip: ^Chip) {
	for i in 0 ..< 8 {
		update_pin(
			.Hi if (value & (1 << auto_cast i)) != 0 else .Low,
			chip.pins[pin_names[i]],
			updated_pins,
		)
	}
}
u16_to_pins :: proc(
	value: u16,
	pin_names: [16]PinName,
	updated_pins: ^[dynamic]^Pin,
	chip: ^Chip,
) {
	for i in 0 ..< 16 {
		update_pin(
			.Hi if (value & (1 << auto_cast i)) != 0 else .Low,
			chip.pins[pin_names[i]],
			updated_pins,
		)
	}
}
u4_to_pins :: proc(value: u8, pin_names: [4]PinName, updated_pins: ^[dynamic]^Pin, chip: ^Chip) {
	for i in 0 ..< 4 {
		update_pin(
			.Hi if (value & (1 << auto_cast i)) != 0 else .Low,
			chip.pins[pin_names[i]],
			updated_pins,
		)
	}
}

render_text :: proc(font: microui.Font, text: string, x, y: i32, color: microui.Color) {
	g := tls.g
	sdl3.SetTextureColorMod(g.atlas_texture, color.r, color.g, color.b)
	sdl3.SetTextureAlphaMod(g.atlas_texture, color.a)

	dst_x := f32(x)
	dst_y := f32(y)

	for ch in text {
		// Clamp to the atlas range; microui's default atlas covers glyphs 32–127
		glyph := int(ch)
		if glyph < 32 || glyph > 127 do glyph = 127

		atlas_rect := microui.default_atlas[microui.DEFAULT_ATLAS_FONT + glyph]

		src := sdl3.FRect {
			x = f32(atlas_rect.x),
			y = f32(atlas_rect.y),
			w = f32(atlas_rect.w),
			h = f32(atlas_rect.h),
		}
		dst := sdl3.FRect {
			x = dst_x,
			y = dst_y,
			w = src.w,
			h = src.h,
		}

		sdl3.RenderTexture(g.renderer, g.atlas_texture, &src, &dst)
		dst_x += src.w
	}
}
render_icon :: proc(id: microui.Icon, rect: microui.Rect, color: microui.Color) {
	g := tls.g
	atlas_rect := microui.default_atlas[int(id)]

	// Center the icon glyph within the destination rect
	dst_x := f32(rect.x) + f32(rect.w - atlas_rect.w) / 2
	dst_y := f32(rect.y) + f32(rect.h - atlas_rect.h) / 2

	src := sdl3.FRect {
		x = f32(atlas_rect.x),
		y = f32(atlas_rect.y),
		w = f32(atlas_rect.w),
		h = f32(atlas_rect.h),
	}
	dst := sdl3.FRect {
		x = dst_x,
		y = dst_y,
		w = src.w,
		h = src.h,
	}

	sdl3.SetTextureColorMod(g.atlas_texture, color.r, color.g, color.b)
	sdl3.SetTextureAlphaMod(g.atlas_texture, color.a)
	sdl3.RenderTexture(g.renderer, g.atlas_texture, &src, &dst)
}
init_microui_atlas :: proc() {
	g := tls.g
	// microui's atlas is a 128x128 single-channel (alpha) image.
	// Expand it to RGBA so SDL can use it: white RGB, atlas value as alpha.
	pixels := make(
		[]u32,
		microui.DEFAULT_ATLAS_WIDTH * microui.DEFAULT_ATLAS_HEIGHT,
		context.temp_allocator,
	)

	for val, i in microui.default_atlas_alpha {
		pixels[i] = 0x00FFFFFF | (u32(val) << 24) // ABGR: alpha from atlas, white RGB
	}

	g.atlas_texture = sdl3.CreateTexture(
		g.renderer,
		.ABGR8888,
		.STATIC,
		microui.DEFAULT_ATLAS_WIDTH,
		microui.DEFAULT_ATLAS_HEIGHT,
	)
	assert(g.atlas_texture != nil)

	sdl3.UpdateTexture(
		g.atlas_texture,
		nil,
		raw_data(pixels),
		microui.DEFAULT_ATLAS_WIDTH * size_of(u32),
	)
	sdl3.SetTextureBlendMode(g.atlas_texture, {.BLEND})
}

is_simulator_thread :: proc() -> bool {
	return lane_id() == 1
}

is_main_thread :: proc() -> bool {
	return lane_id() == 0
}
lane_id :: proc() -> int {
	return tls.lane_id
}
lane_count :: proc() -> int {
	return tls.lane_count
}
lane_sync :: proc() {
	sync.barrier_wait(tls.barrier)
}
lane_range :: proc(count: int) -> (start: int, end: int) {
	lane_count := lane_count()
	lane_id := lane_id()

	values_per_thread := count / lane_count
	leftover_values_count := count % lane_count
	thread_has_leftover := lane_id < leftover_values_count
	leftovers_before_this_thread_idx := lane_id if thread_has_leftover else leftover_values_count

	start = values_per_thread * lane_id + leftovers_before_this_thread_idx
	end = start + values_per_thread + (1 if thread_has_leftover else 0)
	return
}

SCREEN_WIDTH :: 640
SCREEN_HEIGHT :: 480
VGA_WIDTH :: 800
VGA_HEIGHT :: 525
Pixel :: u32


@(thread_local)
tls: TLS

G :: struct {
	should_quit:      bool,
	vga_display:      ^Chip,
	system_clock:     ^Chip,
	chips:            []^Chip,
	busses:           map[BusName]^Bus,
	debugger_enabled: bool,
	frame_complete:   bool,

	//platform
	microui_context:  microui.Context,
	window:           ^sdl3.Window,
	renderer:         ^sdl3.Renderer,
	texture:          ^sdl3.Texture,
	atlas_texture:    ^sdl3.Texture,
}
Pin :: struct {
	chip:  ^Chip,
	bus:   ^Bus,
	name:  PinName,
	value: PinValue,
}
PinValue :: enum {
	X = 0,
	Low,
	Hi,
}
PinName :: enum {
	//various ICs
	MHZ16,
	D0,
	D1,
	D2,
	D3,
	D4,
	D5,
	D6,
	D7,
	nPE, //parallel load enable (active low)
	CEP,
	CET,
	CP, //Clock pulse
	nMR,
	Q0,
	Q1,
	Q2,
	Q3,
	Q4,
	Q5,
	Q6,
	Q7,
	Q8,
	Q9,
	Q10,
	Q11,
	Q12,
	Q13,
	Q14,
	Q15,
	TC,
	CPC,
	nMRC,
	nHSYNC,
	nVSYNC,
	VGAClock,
	RGB,
	VCC,
	GND,

	//logic gates
	A,
	B,
	C,
	Y,
	nS,
	nR,
	Q,
	nQ,
}
Bus :: struct {
	pins: [dynamic]^Pin,
	name: BusName,
}
BusName :: enum {
	MHZ16,
	MHZ8,
	MHZ4,
	MHZ2,
	nVGA_GET,
	nVREG_OE,
	VGA_RGB,
	nHSYNC,
	nVSYNC,
	H1,
	H2,
	H4,
	H8,
	H16,
	H32,
	V1,
	V2,
	V4,
	V8,
	V16,
	V32,
	V64,
	V128,
	V256,
	nMRC,
	VGAFlipFlopSet,
}
Chip :: struct {
	type:          enum {
		SystemClock,
		FourBitCounter, //SN74HC161
		SixteenBitCounter, ////2 SN74HC590s together
		EightBitShiftRegister, ////SN74HC166
		VGADisplay, //made up device to simulate a vga display
		NORGate,
		ORGate,
		ORGate3Input, //made up
		FlipFlop,
		NANDGate,
	},
	pins:          map[PinName]^Pin,

	//FourBitCounter
	fbc_counter:   u8,

	//SixteenBitCounter
	sbc_counter:   u16,

	//EightBitShiftRegister
	ebsr_register: u8,

	//VGA display
	vga_row:       int,
	vga_column:    int,
	vga_pixels:    []Pixel,
}
TLS :: struct {
	g:          ^G,
	lane_id:    int,
	lane_count: int,
	barrier:    ^sync.Barrier,
}


import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import "vendor:microui"
import "vendor:sdl3"
