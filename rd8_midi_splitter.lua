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
	-- check for "RD8_MIDI_Master" track and select the first instance if multiple exist--
	--------------------------------------------------------------------------------------

	local rd8_midi_master_found = false
	local rd8_track_name = "RD8_MIDI_Master"    -- the name of the MIDI Master track to match 
	
	for track in Session:get_tracks():iter() do                                                         --iterate over all tracks in the session
		if (string.find(track:name(), rd8_track_name) and track:data_type():to_string() == "midi") then --check if valid RD8_MIDI_Master exists
			rd8_midi_master_found = true						
			local rd8_midi_master_track = track:to_track():to_midi_track()						        --select the first valid option
			break
            --print(tostring(rd8_midi_master_track:get_playback_channel_mode()))					
			--print(string.format("%x",rd8_midi_master_track:get_playback_channel_mask()))
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
	for rd8_inst_number, rd8_inst in pairs(rd8) do
		table.insert(dialog_options, { type = "checkbox", key = "onoff_"..rd8_inst["inst"], default = false, title = rd8_inst["name"] })	
	end

	table.insert(dialog_options,{ type = "heading", title = "Further options:" })

	table.insert(dialog_options,{ type = "checkbox", key = "auto_connect_to_rd8", default = true, title = "Auto-connect new track outputs to the RD-8"}) 
    table.insert(dialog_options,{ type = "checkbox", key = "create_audio_tracks", default = true, title = "Create audio tracks (Mono) per instrument" })

	local od = LuaDialog.Dialog("RD-8 MIDI Splitter Setup", dialog_options)
	local rv = od:run()

	if not (rv) then goto script_end end

    ----------------------------------------------------
    --check if RD-8 is connected for MIDI auto-connect--
    ----------------------------------------------------
    if rv["auto_connect_to_rd8"] then
        
        local rd8_found = false
        local _, t = Session:engine ():get_backend_ports ("", ARDOUR.DataType("midi"), ARDOUR.PortFlags.IsInput | ARDOUR.PortFlags.IsPhysical, C.StringVector ())

        for __,p in pairs(t[4]:table()) do 
            if (p) then
                if Session:engine (): get_pretty_name_by_name(p) == "RD-8" then
                    local rd8_port = p
                    rd8_found = true
                    break
                end
            end
        end
    end

    if (not rd8_found) and rv["auto_connect_to_rd8"] then
		LuaDialog.Message ("RD-8 disconnected?", "Cannot auto-connect new tracks!", LuaDialog.MessageType.Warning, LuaDialog.ButtonType.Close):run()
	end

	-------------------------------------
	--loop through selected instruments--
	-------------------------------------

	for rd8_inst_id, rd8_inst in pairs(rd8) do
		if rv["onoff_"..rd8_inst["inst"]] then
			--auto-connect to the RD-8 if enabled and found
            if rd8_found then
			    Session:engine (): connect ("ardour:RD8_MIDI_"..rd8_inst["inst"].."/midi_out 1",rd8_port)
		    end

            --MIDI track creation
			local cur_inst_tracklist = Session:new_midi_track(ARDOUR.ChanCount(ARDOUR.DataType("midi"), 1), ARDOUR.ChanCount(ARDOUR.DataType("midi"), 1), false, ARDOUR.PluginInfo(), nil, nil, 1, "RD8_MIDI_"..rd8_inst["inst"], ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal)

			--audio track creation if enabled
            if rv["create_audio_tracks"] then
                Session:new_audio_track(1,2,nil,1,"RD8_"..rd8_inst["inst"],ARDOUR.PresentationInfo.max_order,ARDOUR.TrackMode.Normal)    
            end

            --get the MIDI track from the one-element-list cur_inst_tracklist and filter MIDI data
			for cur_track in cur_inst_tracklist:iter() do
                for region in rd8_midi_master_track:playlist():region_list():iter() do
					if region:isnil() then break end
				
					local new_region = ARDOUR.RegionFactory.clone_region(region, true, true):to_midiregion() 
					
					local midi_model = region:to_midiregion():midi_source(0):model()				
					local midi_command = midi_model:new_note_diff_command("Filter MIDI Events")

					local cur_model = new_region:midi_source(0):model()
					local cur_command = cur_model:new_note_diff_command("Write MIDI Events")
					
					for note in ARDOUR.LuaAPI.note_list (midi_model):iter() do
						if note:note() == rd8_inst["note"] then	     
							local filtered_note = ARDOUR.LuaAPI.new_noteptr(rd8_inst_id, note:time(), note:length(), note:note(), note:velocity())  --separate midi channel per instrument per default
							cur_command:add(filtered_note)			
						end
						cur_command:remove(note)		
					end
			
					midi_model:apply_command(Session, midi_command)
					cur_model:apply_command(Session, cur_command)

					cur_track:playlist():add_region(new_region, region:position(), 1, false, 0, 0, false) 	--add new_region to created instrument track
				end
			end
		end
	end

	::script_end::
end end
