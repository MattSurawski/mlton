(* Copyright (C) 1999-2002 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 * Copyright (C) 1997-1999 NEC Research Institute.
 *
 * MLton is released under the GNU General Public License (GPL).
 * Please see the file MLton-LICENSE for license information.
 *)
structure IEEEReal: IEEE_REAL_EXTRA =
   struct
      val op + = Int.+
      val op - = Int.-
      val op * = Int.*
	 
      exception Unordered
      datatype real_order = LESS | EQUAL | GREATER | UNORDERED

      datatype float_class =
         INF
       | NAN
       | NORMAL
       | SUBNORMAL
       | ZERO
	 
      datatype rounding_mode =
	 TO_NEAREST
       | TO_NEGINF
       | TO_POSINF
       | TO_ZERO

      val intToRounding_mode: int -> rounding_mode =
	 fn 0 => TO_NEAREST
	  | 1 => TO_NEGINF
	  | 2 => TO_POSINF
	  | 3 => TO_ZERO
	  | _ => raise Fail "IEEEReal.intToRounding_mode"

      val rounding_modeToInt: rounding_mode -> int =
	 fn TO_NEAREST => 0
	  | TO_NEGINF => 1
	  | TO_POSINF => 2
	  | TO_ZERO => 3

      structure Prim = Primitive.IEEEReal

      val setRoundingMode = Prim.setRoundingMode o rounding_modeToInt
      val getRoundingMode = intToRounding_mode o Prim.getRoundingMode

      fun withRoundingMode (m: rounding_mode, th: unit -> 'a): 'a =
	 let
	    val m' = getRoundingMode ()
	    val _ = setRoundingMode m
	    val res = th ()
	    val _ = setRoundingMode m'
	 in
	    res
	 end

      type decimal_approx = {class: float_class,
			     digits: int list,
			     exp: int,
			     sign: bool}

      fun 'a scan reader (state: 'a) =
	 let
	    val state = StringCvt.skipWS reader state
	    fun readc (c, state, f) =
	       case reader state of
		  NONE => NONE
		| SOME (c', state') =>
		     if c = Char.toLower c'
			then f state'
		     else NONE
	    fun readString (s, state, failure, success) =
	       let
		  val n = String.size s
		  fun loop (i, state) =
		     if i = n
			then success state
		     else
			case reader state of
			   NONE => failure ()
			 | SOME (c, state) =>
			      if Char.toLower c = String.sub (s, i)
				 then loop (i + 1, state)
			      else failure ()
	       in
		  loop (0, state)
	       end
	    fun charToDigit c = Char.ord c - Char.ord #"0"
	    fun digitStar (ds: int list, state) =
	       let
		  fun done () = (rev ds, state)
	       in
		  case reader state of
		     NONE => done ()
		   | SOME (c, state) =>
			if Char.isDigit c
			   then digitStar (charToDigit c :: ds, state)
			else done ()
	       end
	    fun digitPlus (state, failure, success) =
	       case reader state of
		  NONE => failure ()
		| SOME (c, state) =>
		     if Char.isDigit c
			then success (digitStar ([charToDigit c], state))
		     else failure ()
	    (* [+~-]?[0-9]+ *)
	    type exp = {digits: int list, negate: bool}
	    fun 'b afterE (state: 'a,
			   failure: unit -> 'b,
			   success: exp * 'a -> 'b)
	       : 'b =
	       case reader state of
		  NONE => failure ()
		| SOME (c, state) =>
		     let
			fun neg () =
			   digitPlus (state, failure,
				      fn (ds, state) =>
				      success ({digits = ds, negate = true},
					       state))
		     in
			case c of
			   #"+" => digitPlus (state, failure,
					      fn (ds, state) =>
					      success ({digits = ds,
							negate = false},
						       state))
			 | #"~" => neg ()
			 | #"-" => neg ()
			 | _ =>
			      if Char.isDigit c
				 then
				    let
				       val (ds, state) =
					  digitStar ([charToDigit c], state)
				    in
				       success ({digits = ds, negate = false},
						state)
				    end
			      else failure ()
		     end
	    (* e[+~-]?[0-9]+)? *)
	    fun exp (state: 'a, failure, success) =
	       case reader state of
		  NONE => failure ()
		| SOME (c, state) =>
		     case Char.toLower c of
			#"e" => afterE (state, failure, success)
		      | _ => failure ()
	    (* (\.[0-9]+)(e[+~-]?[0-9]+)? *)
	    fun 'b afterDot (state: 'a,
			     failure: unit -> 'b,
			     success: int list * exp * 'a -> 'b) =
	       digitPlus (state, failure,
			  fn (frac, state) =>
			  exp (state,
			       fn () => success (frac,
						 {digits = [], negate = false},
						 state),
			       fn (e, state) => success (frac, e, state)))
	    fun stripLeadingZeros (ds: int list): int * int list =
	       let
		  fun loop (i, ds) =
		     case ds of
			[] => (i, [])
		      | d :: ds' =>
			   if d = 0
			      then loop (i + 1, ds')
			   else (i, ds)
	       in
		  loop (0, ds)
	       end
	    fun stripTrailingZeros ds =
	       rev (#2 (stripLeadingZeros (rev ds)))
	    fun done (whole: int list,
		      frac: int list,
		      {digits: int list, negate: bool},
		      state: 'a) =
	       let
		  val (_, il) = stripLeadingZeros whole
		  val fl = stripTrailingZeros frac
		  fun exp (): int =
		     let
			val e = List.foldl (fn (d, n) => n * 10 + d) 0 digits
		     in
			if negate then Int.~ e else e
		     end
		  val da =
		     case il of
			[] =>
			   (case fl of
			       [] => {class = ZERO,
				      digits = [],
				      exp = 0,
				      sign = false}
			     | _ =>
				  let
				     val (m, fl) = stripLeadingZeros fl
				  in
				     {class = NORMAL,
				      digits = fl,
				      exp = exp () - m,
				      sign = false}
				  end)
		      | _ => {class = NORMAL,
			      digits = stripTrailingZeros (il @ fl),
			      exp = exp () + length il,
			      sign = false}
	       in
		  SOME (da, state)
	       end
	    fun normal' (c, state) =
	       case Char.toLower c of
		  #"i" => readc (#"n", state, fn state =>
				 readc (#"f", state, fn state =>
					let
					   fun res state =
					      SOME ({class = INF,
						     digits = [],
						     exp = 0,
						     sign = false},
						    state)
					in
					   readString ("inity", state,
						       fn () => res state,
						       res)
					end))
		| #"n" => readc (#"a", state, fn state =>
				 readc (#"n", state, fn state =>
					SOME ({class = NAN,
					       digits = [],
					       exp = 0,
					       sign = false},
					      state)))
		(* (([0-9]+(\.[0-9]+)?)|(\.[0-9]+))(e[+~-]?[0-9]+)? *)
		| #"." => afterDot (state,
				    fn () => NONE,
				    fn (frac, exp, state) =>
				    done ([], frac, exp, state))
		| _ =>
		     if Char.isDigit c
			then
			   (* ([0-9]+(\.[0-9]+)?)(e[+~-]?[0-9]+)? *)
			   let
			      val (whole, state) =
				 digitStar ([charToDigit c], state)
			      fun no () = done (whole, [],
						{digits = [], negate = false},
						state)
			   in
			      case reader state of
				 NONE => no ()
			       | SOME (c, state) =>
				    case Char.toLower c of
				       #"." =>
				       afterDot (state, no,
						 fn (frac, e, state) =>
						 done (whole, frac, e, state))
				     | #"e" =>
					  afterE (state, no,
						  fn (e, state) =>
						  done (whole, [], e, state))
				     | _ => no ()
			   end
		     else NONE
	    val normal' = fn z => normal' z handle Overflow => NONE
	    fun normal state =
	       case reader state of
		  NONE => NONE
		| SOME z => normal' z
	    fun negate state =
	       case normal state of
		  NONE => NONE
		| SOME ({class, digits, exp, sign}, state) =>
		     SOME ({class = class,
			    digits = digits,
			    exp = exp,
			    sign = true},
			   state)
	 in
	    case reader state of
	       NONE => NONE
	     | SOME (c, state) =>
		  case c of
		     #"~" => negate state
		   | #"-" => negate state
		   | #"+" => normal state
		   | _ => normal' (c, state)
	 end

      fun fromString s = StringCvt.scanString scan s

      fun toString {class, sign, digits, exp}: string =
	 let
	    fun digitStr () = implode (map StringCvt.digitToChar digits)
	    fun norm () =
	       let val num = "0." ^ digitStr()
	       in if exp = 0
		     then num
		  else concat [num, "E", Int.toString exp]
	       end
	    val num =
	       case class of
		  ZERO => "0.0"
		| NORMAL => norm ()
		| SUBNORMAL => norm ()
		| INF => "inf"
		| NAN => "nan"
	 in if sign
	       then "~" ^ num
	    else num
	 end
   end

