ardour { 	
			["type"] = "EditorAction", 
			name = "RD-8 MIDI Splitter", 
			license = "MIT",
			author = "dotted_pi",
			description = [[This script exports user-selected RD-8 instruments and filters an 'RD8_MIDI_Master' track into a unique MIDI (and Mono) track per instrument.]] 
		}

function factory () return function ()

	------------------------------------------------------------------------------------
	--set up the RD-8 class containing all instruments with their midi notes and names--
	------------------------------------------------------------------------------------

	local rd8 = {

		{inst = "kick", note = 36, name = "Kick"},

		{inst = "snare", note = 40, name = "Snare"},

		{inst = "low_ct", note = 45, name = "Low Conga/Tom"},

		{inst = "mid_ct", note = 47,  name = "Mid Conga/Tom"},

		{inst = "high_ct", note = 50,  name = "High Conga/Tom"},

		{inst = "cl_rs", note = 37,  name = "Claves/Rim Shot"},

		{inst = "clap", note = 39,  name = "Maracas/Claps"},

		{inst = "cowbell", note = 56,  name = "Cowbell"},

		{inst = "cymbal", note = 51,  name = "Cymbal"},

		{inst = "openhat", note = 46,  name = "Open Hat"},

		{inst = "closedhat", note = 42,  name = "Closed Hat"},

	}

	--------------------------------------------------------------------------------------
	--search for "RD8_MIDI_Master" track and select the first instance if multiple exist--
	--------------------------------------------------------------------------------------

	local rd8_midi_master_found = false
	local rd8_track_name = "RD8_MIDI_Master"    -- the name of the MIDI Master track to match 
	
	for track in Session:get_tracks():iter() do 
		if track:data_type():to_string() == "midi" then                                         --iterate over all MIDI tracks in the session
			if (not rd8_midi_master_found) and (string.find(track:name(), rd8_track_name)) then --check if valid RD8_MIDI_Master exists
				rd8_midi_master_found = true						
				rd8_midi_master_track = track:to_track():to_midi_track()						        --select the first valid option 
			end

			--check if the MIDI track is an instrument MIDI track as created by the script (and get its ID)
			
			for rd8_inst_id, rd8_inst in pairs(rd8) do
				if string.find(track:name(),"RD8_MIDI_"..rd8_inst["inst"]) then
					rd8[rd8_inst_id]["MIDI_track_found"] = true
					rd8[rd8_inst_id]["MIDI_track_id"] = track:to_stateful():id()	
				end
			end
		end
	end

	if not rd8_midi_master_found then
		LuaDialog.Message ("Setup Error", "No valid 'RD8_MIDI_Master' track could be found!", LuaDialog.MessageType.Error, LuaDialog.ButtonType.Close):run()
		goto script_end
	end

	-------------------------------------------
	--create setup dialog and save user input--
	-------------------------------------------
	
	local dialog_options = {}

	table.insert(dialog_options, { type = "heading", title = "Select instruments to create their MIDI track:" })
	
	for _, rd8_inst in pairs(rd8) do
		table.insert(dialog_options, { type = "checkbox", key = "sel_"..rd8_inst["inst"], default = false, title = rd8_inst["name"] })	
	end

	table.insert(dialog_options,{ type = "heading", title = "Further options:" })

	table.insert(dialog_options,{ type = "checkbox", key = "auto_connect_to_rd8", default = false, title = "Auto-connect new track outputs to the RD-8"}) 
    table.insert(dialog_options,{ type = "checkbox", key = "create_audio_tracks", default = false, title = "Create audio tracks (Mono) per instrument" })

	local od = LuaDialog.Dialog("RD-8 MIDI Splitter Setup", dialog_options)
	local rv = od:run()

	if not (rv) then goto script_end end

    ----------------------------------------------------
    --check if RD-8 is connected for MIDI auto-connect--
    ----------------------------------------------------
    
	if rv["auto_connect_to_rd8"] then
        
        local rd8_found = false
        local _, t = Session:engine():get_backend_ports("", ARDOUR.DataType("midi"), ARDOUR.PortFlags.IsInput | ARDOUR.PortFlags.IsPhysical, C.StringVector ())

        for _, p in pairs(t[4]:table()) do 
            if Session:engine():get_pretty_name_by_name(p) == "RD-8" then
                local rd8_port = p
                rd8_found = true
                break
            end
        end
    end

    if (not rd8_found) and rv["auto_connect_to_rd8"] then
		LuaDialog.Message("RD-8 disconnected?", "Cannot auto-connect new tracks!", LuaDialog.MessageType.Warning, LuaDialog.ButtonType.Close):run()
	end

	--------------------------------------------
	--main loop (through selected instruments)--
	--------------------------------------------
	
	for rd8_inst_id, rd8_inst in pairs(rd8) do
		if rv["sel_"..rd8_inst["inst"]] then
			--auto-connect to the RD-8 if enabled and found
            if rd8_found then
			    Session:engine():connect("ardour:RD8_MIDI_"..rd8_inst["inst"].."/midi_out 1",rd8_port)
		    end

            --MIDI track creation if it does not exist 
			if not rd8_inst["MIDI_track_found"] then
				--[[local cur_inst_tracklist = ]]Session:new_midi_track(ARDOUR.ChanCount(ARDOUR.DataType("midi"), 1), ARDOUR.ChanCount(ARDOUR.DataType("midi"), 1), false, ARDOUR.PluginInfo(), nil, nil, 1, "RD8_MIDI_"..rd8_inst["inst"], ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal)
				rd8_inst["MIDI_track_id"] = Session:route_by_name("RD8_MIDI_"..rd8_inst["inst"]):to_stateful():id()
			end 

			--audio track creation if enabled
            if rv["create_audio_tracks"] then
                Session:new_audio_track(1,2,nil,1,"RD8_"..rd8_inst["inst"],ARDOUR.PresentationInfo.max_order,ARDOUR.TrackMode.Normal)    
            end

            --get the MIDI track for the current instrument 
			local cur_track = Session:route_by_id(rd8_inst["MIDI_track_id"]):to_track()
                
			for region in rd8_midi_master_track:playlist():region_list():iter() do
				if region:isnil() then break end
			
				local new_region = ARDOUR.RegionFactory.clone_region(region, true, true):to_midiregion() 
				
				local midi_model = region:to_midiregion():midi_source(0):model()				
				local midi_command = midi_model:new_note_diff_command("Write MIDI Events")

				local cur_model = new_region:midi_source(0):model()
				local cur_command = cur_model:new_note_diff_command("Filter MIDI Events")

				--filter notes per region and copy them if they belong to the current instrument  
				for note in ARDOUR.LuaAPI.note_list (midi_model):iter() do
					if note:note() == rd8_inst["note"] then	     
						local filtered_note = ARDOUR.LuaAPI.new_noteptr(rd8_inst_id, note:time(), note:length(), note:note(), note:velocity())  --separate midi channel per instrument per default
						cur_command:add(filtered_note)			
					end
					cur_command:remove(note)		
				end
	
				cur_track:playlist():add_region(new_region, region:position(), 1, false, 0, 0, false) 	--add new_region to created instrument track
				midi_model:apply_command(Session, midi_command)
				cur_model:apply_command(Session, cur_command)
			end		
		end
	end

	rd8_midi_master_track = nil

	::script_end::
end end


---------------------------------		
--define an icon for the script--
---------------------------------

function icon (params) return function (ctx, width, height, fg)
	ctx:set_source_rgba(0.99, 0.41, 0.12,1) --"RD-8" fontcolor on the device 
	local txt = Cairo.PangoLayout(ctx, "ArdourMono " .. math.ceil(math.min(width, height) * 0.3+2) .. "px")
	txt:set_text("RD-8\nMIDI")
	local tw, th = txt:get_pixel_size()
	ctx:move_to(0.5 * (width - tw)+1, 0.5 * (height - th))
	txt:show_in_cairo_context(ctx)
end end
