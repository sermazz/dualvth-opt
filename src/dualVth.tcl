##############################################################################################
#                                                                                            #
#                                SODS Low-power Contest 2019                                 #
#                              Polytechnic University of Turin                               #
#                                  	   Sergio Mazzola                                        #
#                                                                                            #
# Filename: dualVth.tcl                                                                		 #
# Author: Sergio Mazzola                                                                     #
# Last edit: 07/07/2019                                                                      #
# Brief: Synopsys PrimeTime algorithm for the search of a tradeoff between worst			 #
#		 case slack and dynamic power consumption under leakage constraint, in				 #
#		 the shortes possible time                                                           #
#                                                                                            #
##############################################################################################

proc swap_to_HVT { cell } {
	set ref_name [get_attribute $cell ref_name] 
	
	#Substitute the second "L" with an "H" in the "_LL_" (or "_LLS_")
	#part to swap the cell with its HVT alternative
	regsub {_LL} $ref_name {_LH} refname_HVT
	size_cell -libraries CORE65LPHVT $cell "$refname_HVT"
	
	return
}

proc swap_to_LVT { cell } {
	set ref_name [get_attribute $cell ref_name] 
	
	#Substitute the "H" with an "L" in the "_LH_" (or "_LHS_")
	#part to swap the cell with its HVT alternative
	regsub {_LH} $ref_name {_LL} refname_LVT
	size_cell -libraries CORE65LPLVT $cell "$refname_LVT"
	
	return
}

proc swap_to_smaller { cell } {
	# Returns 1 if the swap succeded, 0 if no alternatives were found
	set ref_name [get_attribute $cell ref_name]
	
	#Detect type and function of given cell (also store its size) and collect alternatives
	regexp {^.*(L[LH]S?_[\w]*)X(\d*)$} $ref_name - cell_type size
	set alternatives [lsearch -all -inline -regexp [get_alternative_lib_cells $cell -base_names -current_library] ".*$cell_type.*"]
	
	lappend alternatives $ref_name
	set alternatives [lsort -dictionary -increasing $alternatives]
	set target [expr [lsearch -sorted -increasing -dictionary $alternatives $ref_name] - 1]
	
	if { $target >= 0 } {
		#Take the biggest cell smaller than the given cell
		size_cell $cell [lindex $alternatives $target]
		return 1
	}
	return 0
}

proc swap_to_bigger { cell } {
	# Returns 1 if the swap succeded, 0 if no alternatives were found
	set ref_name [get_attribute $cell ref_name]
	
	#Detect type and function of given cell (also store its size) and collect alternatives
	regexp {^.*(L[LH]S?_[\w]*)X(\d*)$} $ref_name - cell_type size
	set alternatives [lsearch -all -inline -regexp [get_alternative_lib_cells $cell -base_names -current_library] ".*$cell_type.*"]
	
	lappend alternatives $ref_name
	set alternatives [lsort -dictionary -decreasing $alternatives]
	set target [expr [lsearch -sorted -decreasing -dictionary $alternatives $ref_name] - 1]
	
	if { $target >= 0 } {
		#Take the smallest cell bigger than the given cell
		size_cell $cell [lindex $alternatives $target]
		return 1
	}
	return 0
}

proc evaluate_cost_fun {} {
	#Get dynamic power of whole design
	set dp [get_attribute [current_design] dynamic_power]
	#Get slack of max delay path (worst case slack)
	set slack [get_attribute [get_timing_path] slack]
	
	#Cost function evaluation
	#The cost function only depends on the dynamic power if the slack is positive, so that
	#higher power savings are allowed; if instead the worst case slack is negative, the
	#cost function mainly depends on the slack, and the cost increases exponentially as
	#the slack becomes more negative
	if {$slack < 0} {
		return [expr $dp/exp($slack)]
	} else {
		return $dp
	}
}





proc dualVth {args} {
	parse_proc_arguments -args $args results
	set savings $results(-savings)

	puts $savings

##############################################################################################
#                                             HEADER                                         #
##############################################################################################

	#Save arrival time and slack for pins
	global timing_save_pin_arrival_and_slack
	set timing_save_pin_arrival_and_slack true
	#Set LVT and HVT group cell attributes
	set_user_attribute -quiet [find library CORE65LPLVT] default_threshold_voltage_group LVT
	set_user_attribute -quiet [find library CORE65LPHVT] default_threshold_voltage_group HVT

	suppress_message LNK-041	;#accessing library not linked in current design
	suppress_message NED-045	;#resizing gate
	suppress_message PWR-246	;#using default switching activity propagation
	suppress_message PWR-601	;#running averaged power analysis
	suppress_message PTE-018 	;#abandoning fast timing updates
	suppress_message UIAT-4		;#attribute already defined

##############################################################################################
#                                              MAIN                                          #
##############################################################################################

	#Define new user attribute to easily manage the collection
	define_user_attribute -type double -classes cell leak_diff
	define_user_attribute -type float -classes cell wc_slack
	define_user_attribute -type double -classes cell priority_leak

	#Evaluate initial cost function
	set currentCF [evaluate_cost_fun]

	#Initialize starting leakage power
	set startLeak [get_attribute [current_design] leakage_power]
	set targetLeak [expr $startLeak*(1-$savings)]
	
	set gamma 0

##############################################################################################
#################################### Main optimization loop ##################################

	set iterations 0

	#DEBUG
	puts "Launching optimization loop..."
	puts "Requested leakage savings = [expr $savings*100]%"

	while {1} {

		#Recompute max_slack of each cell due to changes in size and Vth of previous iteration
		foreach_in_collection cell [get_cells] {
			set out_pin [get_pins -of_object $cell -filter {direction == out}]
			set_user_attribute -quiet -class cell $cell wc_slack [get_attribute $out_pin max_slack] 
		}
		
##############################################################################################
################################## Slack/dynamic power tradeoff ##############################
		
		#Compute epsilon as a function of the worst case max_slack
		set wc_slack [get_attribute [get_timing_path] slack]
		
		if {$wc_slack <= 0} {
			set epsilon	[expr $wc_slack*(1 - exp(4*$wc_slack))]
		} else {
			set epsilon 0
		}
		
		#DEBUG
		puts "\n************** Iteration #${iterations} **************"
		puts "Cost function: $currentCF"
		puts "Slack = $wc_slack ns | DP = [get_attribute [current_design] dynamic_power] W\n"
		puts -nonewline "epsilon = "
		puts -nonewline [format "%.3f" $epsilon]
		puts -nonewline " ns | gamma = "
		puts -nonewline [format "%.3f" $gamma]
		puts " ns"
		
		#Dictionaries to store the substitutions and revert them quickly in case the cost
		#function turns out to worsen with a given transformation
		set resized2Small [dict create]
		set resized2Big [dict create]
		
		#Inspect the slack of all cells in the design: 
		#- All cells whose slack is less than epsilon are replaced with bigger cells: epsilon
		#  is always negative (or 0) so it is not likely that a negative slack will be brought
		#  back to a positive slack, but a too high epsilon would lead to substitute too much
		#  cells with bigger alternatives, making impossible to achieve the constraint on the
		#  leakage power and a good tradeoff with the dynamic power (also too many big cells
		#  create more load to be driven, which is also cause of higher delays, thus only most
		#  critical of the critical cells are swapped to bigger)
		#- All cells whose slack is higher than gamma are considered not critical and can be
		#  swapped to smaller alternatives to save some dynamic power; gamma is always 0: this
		#  is because if the wc slack is negative, we don't care if other cells get a negative
		#  slack, as long as it remaing within the worst one; moreover, if the cost function
		#  improves, such cells will be anyway swapped again to bigger when needed
		#- All the cells in between are in a safe zone and are not affected by transformations
		#  of this iteration (but they might be touched by global effects of delay)
		
		#Note that each cell is resized of only 1 size per iteratin (1 size bigger or 1 size
		#smaller): this allows to better explore the cost function; if the cell needs further
		#transformation, it will remain below epsilon or above gamma, and will be further
		#resized on next iteration
		
		foreach_in_collection cell [get_cells] {
			set cell_slack [get_attribute $cell wc_slack]
			set libcell [get_attribute [get_attribute $cell lib_cell] full_name]
			
			if { $cell_slack <= $epsilon } { 
				#Swap to bigger
				if { [swap_to_bigger $cell] == 1 } { dict append resized2Big $cell $libcell	}
			} elseif { $cell_slack >= $gamma } { 
				#Swap to smaller
				if { [swap_to_smaller $cell] == 1 } { dict append resized2Small $cell $libcell }
			}
			
			#Note how if a transformation happens the cell reference and its libcell reference
			#(taken before the transformation) are stored in a dictionary in order to quickly
			#access such information if an undo is needed
		}
		
		#DEBUG
		puts "\nSWAPPED: to smaller = [dict size $resized2Small]"
		puts "         to bigger = [dict size $resized2Big]"
		
################################### Achieve leakage constraint ###############################
##############################################################################################

		#At the end of each optimization iteration of slack/dynamic power, the constraint on
		#the leakage power consumption is enforced
		
		#Compute the current leakage of the design, which changed due to the previous resizes
		set currLeak [get_attribute [current_design] leakage_power]
		
		#Dictionary to rapidly revert the transformation in case this optimization iteration
		#has to be undone
		set swapped2HVT [dict create]
		
		if { $currLeak > $targetLeak } {
			
			#Create a collection of all the LVT cells in the design; only the remaining LVT
			#cells are considered at each iteration, and not the cells which were swapped to
			#HVT in previous iterations; this proved to be better with respect to reswapping
			#from scratch at each iteration because it does not mess up the work done so far
			set cellCollection_LVT [get_cells -filter {lib_cell.threshold_voltage_group == "LVT"}]
			
			#Store individual leakage powers and max_slack of the considered LVT cells
			foreach_in_collection cell $cellCollection_LVT {
				#Temporary store the LVT leakage into leak_diff attribute
				set_user_attribute -quiet -class cell $cell leak_diff [get_attribute $cell leakage_power]
				#Take the max_slack of the output pin of the cell (assuming all cells have only 1 output)
				set out_pin [get_pins -of_object $cell -filter {direction == out}]
				set_user_attribute -quiet -class cell $cell wc_slack [get_attribute $out_pin max_slack] 
			}
			
			#Swap all LVT cells to HVT while creating the dictionary
			foreach_in_collection cell $cellCollection_LVT {
				set libcell [get_attribute [get_attribute $cell lib_cell] full_name]
				dict append swapped2HVT [get_attribute $cell full_name] $libcell
				swap_to_HVT $cell
			}
			
			#With HVT cells only, compute the leakage power of each cell and the index for
			#the priority to decide which cells to make LVT or HVT, among the cells of the
			#initial collection of LVT cells only
			foreach_in_collection cell $cellCollection_LVT {
				#leak_diff is the saving of leakage obtained by swapping $cell from LVT to HVT
				set leak_diff [expr [get_attribute $cell leak_diff] - [get_attribute $cell leakage_power]]
				set_user_attribute -quiet -class cell $cell leak_diff $leak_diff
				
				#Recover the slack saved when all cells of the collection were LVT
				set cellLVT_slack [get_attribute $cell wc_slack]
				
				#Priority should be dependent on max_slack to achieve the constraint while
				#keeping low the worst slack; however making the leakage difference influent
				#too, a good trade-off between number of cells swapped to HVT (the lower, the
				#better) and worsening of the slack can be achieved; it is important not to
				#swap too much cells to HVT because the slowdown is not only local but
				#influences other cells on the same paths
				set priority [expr $leak_diff*$cellLVT_slack]
				set_user_attribute -quiet -class cell $cell priority_leak $priority
			}
			
			#Sort cells by priority index (ascending by default = from worst to best for LVT->HVT swap)
			set cellCollection_LVT [sort_collection $cellCollection_LVT priority_leak]

			set currLeak [get_attribute [current_design] leakage_power]

			#Swap backward from the head of the sorted collection (most critical cells); cells
			#are swapped back from HVT to LVT until the minimum amount of HVT cells to satisfy
			#the leakage power constraint is reached
			#With such approach, we can exactly calculate this minimum without running a power
			#report after each swap: we are exploiting the fact that leakage power is a local
			#property, so that we can keep its count updated simply adding the leak_diff of
			#each swapped cell to the current count of the leakage power
			foreach_in_collection cell $cellCollection_LVT {
				set currLeak [expr $currLeak + [get_attribute $cell leak_diff]]
				if { $currLeak >= $targetLeak } {
					#When next swap would not be compliant with the constraint, break loop
					break
				} else {
					set swapped2HVT [dict remove $swapped2HVT [get_attribute $cell full_name]]
					swap_to_LVT $cell
				}
			}
		}
		
		#DEBUG
		puts "         to HVT = [dict size $swapped2HVT]"
		puts "******************************************"
		
##############################################################################################
#################################### Cost function evaluation ################################
		
		set previousCF $currentCF
		set currentCF [evaluate_cost_fun]
		
		#At least the first iteration is finalized and not reverted, to enforce the constraint
		#on leakage at least one time; the following iterations are instead actually subject
		#to the check on the reduction of the cost function
		if { $iterations > 0 && $currentCF >= $previousCF } {
		
			#DEBUG
			puts "\nLast cost function = $currentCF"
			puts "Slack [get_attribute [get_timing_path] slack] ns |  DP [get_attribute [current_design] dynamic_power] W"
			puts "Local minimum reached\nUndoing last iteration..."
			
			dict for {key value} $swapped2HVT { size_cell $key $value }
			dict for {key value} $resized2Big {	size_cell $key $value }
			dict for {key value} $resized2Small { size_cell $key $value }
			
			#DEBUG
			puts "Optimization concluded\n"
			
			break
		} elseif { [incr iterations] >= 6 } {
			#After 6 iterations of optimization, if a minimum in the cost function has not
			#been reached yet, break anyway the loop to not waste too much time
			
			#DEBUG
			puts "Max number of iteration reached (6)\nOptimization concluded\n"
			
			break
		}
	}

	return
}

define_proc_attributes dualVth \
-info "Post-Synthesis Dual-Vth cell assignment" \
-define_args \
{
	{-savings "minimum % of leakage savings in range [0, 1]" value float required}
}
