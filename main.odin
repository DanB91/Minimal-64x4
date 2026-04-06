#+feature dynamic-literals
package main

main :: proc() {
	lane_count := 2 //os.get_processor_core_count()
	g := new(G)
	g.vga.framebuffer = make([]Pixel, VGA_WIDTH * VGA_HEIGHT)
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
			fmt.printfln("dt main thread: %v", dt)
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
		if is_simulator_thread() && !g.debugger_enabled {
			fmt.printfln("dt: %v", dt)

			TARGET_FRAME_TIME :: 16_666_666
			SYSTEM_CLOCK_TICK_TIME_NS :: 1_000_000_000 / 16_000_000
			VGA_TICK_TIME_NS :: 1_000_000_000 / 25_175_000


			//update system
			assert(sdl3.GetCurrentTime(&now))

			for total_time := 0; total_time < TARGET_FRAME_TIME; total_time += VGA_TICK_TIME_NS {
				if next_vga_tick <= 0 {
					//TODO: tick VGA
					next_vga_tick += VGA_TICK_TIME_NS
				}
				if next_system_tick <= 0 {
					tick_system_clock()
					next_system_tick += SYSTEM_CLOCK_TICK_TIME_NS
				}
				next_vga_tick -= VGA_TICK_TIME_NS
				next_system_tick -= VGA_TICK_TIME_NS
			}
			tmp := now
			assert(sdl3.GetCurrentTime(&now))
			fmt.printfln("time taken: %vns", now - tmp)

		}
		lane_sync()

		if is_main_thread() {
			mctx := &g.microui_context
			microui.begin(mctx)
			microui.begin_window(mctx, "Debugger", microui.Rect{0, 0, 500, 400}, {.NO_CLOSE})

			b: strings.Builder
			strings.builder_init(&b, context.temp_allocator)
			for chip in g.chips {
				fmt.sbprintf(&b, "%s -- ", chip.type)
				for name, pin in chip.pins {
					fmt.sbprintf(&b, "%s: %s,", name, pin.value)
				}
				microui.layout_row(mctx, {-1})
				microui.text(mctx, strings.to_string(b))
				strings.builder_reset(&b)

			}
			microui.checkbox(mctx, "Enable Debugger", &g.debugger_enabled)
			opt := microui.Options{.ALIGN_CENTER}
			if !g.debugger_enabled {
				opt |= {.NO_INTERACT}
			}
			if .SUBMIT in microui.button(mctx, "Step", opt = opt) {
				tick_system_clock()
			}

			microui.end_window(mctx)
			microui.end(mctx)

		}
		lane_sync()

		if is_main_thread() {

			viewport := sdl3.Rect{144, 35, SCREEN_WIDTH, SCREEN_HEIGHT}
			viewport_f := sdl3.FRect{144, 35, SCREEN_WIDTH, SCREEN_HEIGHT}

			sdl3.RenderClear(g.renderer)

			raw_pixels: [^]Pixel
			pitch: c.int
			assert(sdl3.LockTexture(g.texture, &viewport, auto_cast &raw_pixels, &pitch))
			pixels := raw_pixels[0:(pitch / 4) * SCREEN_HEIGHT]
			copy(pixels, g.vga.framebuffer)
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
tick_system_clock :: proc() {
	g := tls.g
	system_clock_pin := &g.system_clock.pins[.MHZ16]
	system_clock_pin.value = .Hi if system_clock_pin.value == .Low else .Low
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
				update_chip := pin.value != new_value
				if update_chip {
					pin.value = new_value
					switch new_value {
					case .Hi:
						on_rising_edge(pin, &updated_pins)
					case .Low:
						on_falling_edge(pin, &updated_pins)
					case .X:
					//high impedence, do nothing
					}
				}
			}
		}
	}

}

on_rising_edge :: proc(pin: ^Pin, updated_pins: ^[dynamic]^Pin) {

	update_pin :: proc(new_value: PinValue, pin: ^Pin, updated_pins: ^[dynamic]^Pin) {
		if new_value != pin.value {
			pin.value = new_value
			append(updated_pins, pin)
		}
	}

	chip := pin.chip

	switch pin.chip.type {
	case .FourBitCounter:
		//We only care about CP, Q0, Q1, and Q2 in this
		//computer, so we don't need to consider any other pins
		if pin.name == .CP {
			chip.four_bit_counter_state += 1
			chip.four_bit_counter_state &= 0xF
			output_pins :: [?]PinName{.Q0, .Q1, .Q2, .Q3}
			for pin_name, i in output_pins {
				output_pin := &chip.pins[pin_name]
				new_value: PinValue =
					.Hi if (chip.four_bit_counter_state & (1 << cast(uint)i)) != 0 else .Low
				update_pin(new_value, output_pin, updated_pins)

			}
		}
	case .NORGate:
		a := &chip.pins[.A]
		b := &chip.pins[.B]
		y := &chip.pins[.Y]
		result := !(a.value == .Hi || b.value == .Hi)
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .ORGate:
		a := &chip.pins[.A]
		b := &chip.pins[.B]
		y := &chip.pins[.Y]
		result := a.value == .Hi || b.value == .Hi
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)
	case .NANDGate:
		a := &chip.pins[.A]
		b := &chip.pins[.B]
		y := &chip.pins[.Y]
		result := !(a.value == .Hi && b.value == .Hi)
		new_value: PinValue = .Hi if result else .Low
		update_pin(new_value, y, updated_pins)


	case .SystemClock:
	//System clock is handled directly in the main loop

	}
}

on_falling_edge :: proc(pin: ^Pin, updated_pins: ^[dynamic]^Pin) {
	//TODO handle logic gates

}


build_the_computer :: proc() {
	g := tls.g
	chips: [dynamic]Chip
	//System clock
	append(&chips, Chip{type = .SystemClock})
	g.busses[.MHZ16] = Bus{nil, .MHZ16}
	g.system_clock = &chips[len(chips) - 1]
	g.system_clock.pins[.MHZ16] = {g.system_clock, &g.busses[.MHZ16], .MHZ16, .Low}
	system_clock_pin := &g.system_clock.pins[.MHZ16]
	append(&system_clock_pin.bus.pins, &g.system_clock.pins[.MHZ16])

	//Four bit counter
	g.busses[.MHZ8] = Bus{nil, .MHZ8}
	g.busses[.MHZ4] = Bus{nil, .MHZ4}
	g.busses[.MHZ2] = Bus{nil, .MHZ2}
	append(&chips, Chip{})
	four_bit_counter := &chips[len(chips) - 1]
	four_bit_counter.type = .FourBitCounter
	//All data pins are tied high, so counter starts off at 0xF
	//(actually it should start at 0 and then jump to 0xF on the 2nd cycle, but this should be okay)
	four_bit_counter.four_bit_counter_state = 0xF
	four_bit_counter.pins = {
		.CP = {four_bit_counter, &g.busses[.MHZ16], .CP, system_clock_pin.value},
		.Q0 = {four_bit_counter, &g.busses[.MHZ8], .Q0, .Hi},
		.Q1 = {four_bit_counter, &g.busses[.MHZ4], .Q1, .Hi},
		.Q2 = {four_bit_counter, &g.busses[.MHZ2], .Q2, .Hi},
		.Q3 = {four_bit_counter, nil, .Q3, .Hi}, //Q3 is not connected to anything, but here consistency

		//Don't care about any other pins on the four bit counter since theyre all tied high
	}
	for _, &pin in four_bit_counter.pins {
		if pin.bus != nil {
			append(&pin.bus.pins, &pin)
		}
	}

	//TODO build rest of chips

	g.chips = chips[:]
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
	vga:              struct {
		//inputs
		color:        Pin, //Hi for white, Low for black
		hsync, vsync: Pin,
		pixel_clock:  sdl3.Time,
		x, y:         int,
		framebuffer:  []Pixel,
	},
	system_clock:     ^Chip,
	chips:            []Chip,
	busses:           map[BusName]Bus,
	debugger_enabled: bool,

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
	MHZ16,
	D0,
	D1,
	D2,
	D3,
	nPE,
	CEP,
	CET,
	CP,
	nMR,
	Q0,
	Q1,
	Q2,
	Q3,
	TC,

	//logic gates
	A,
	B,
	Y,

	//shared
	VCC,
	GND,
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
}
Chip :: struct {
	type:                   enum {
		SystemClock,
		FourBitCounter, //SN74HC161
		NORGate,
		ORGate,
		NANDGate,
	},
	pins:                   map[PinName]Pin,

	//FourBitCounter
	four_bit_counter_state: int,
}
TLS :: struct {
	g:          ^G,
	lane_id:    int,
	lane_count: int,
	barrier:    ^sync.Barrier,
}


import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "vendor:microui"
import "vendor:sdl3"
