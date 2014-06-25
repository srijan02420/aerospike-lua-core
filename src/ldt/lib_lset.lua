-- AS Large Set (LSET) Operations
-- ======================================================================
-- Copyright [2014] Aerospike, Inc.. Portions may be licensed
-- to Aerospike, Inc. under one or more contributor license agreements.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--  http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- ======================================================================
--
-- Track the date and iteration of the last update.
local MOD="lib_lset_2014_06_24.A"; 

-- This variable holds the version of the code. It should match the
-- stored version (the version of the code that stored the ldtCtrl object).
-- If there's a mismatch, then some sort of upgrade is needed.
-- This number is currently an integer because that is all that we can
-- store persistently.  Ideally, we would store (Major.Minor), but that
-- will have to wait until later when the ability to store real numbers
-- is eventually added.
local G_LDT_VERSION = 2;

-- ======================================================================
-- || GLOBAL PRINT and GLOBAL DEBUG ||
-- ======================================================================
-- Use these flags to enable/disable global printing (the "detail" level
-- in the server).
-- Usage: GP=F and trace()
-- When "F" is true, the trace() call is executed.  When it is false,
-- the trace() call is NOT executed (regardless of the value of GP)
-- (*) "F" is used for general debug prints
-- (*) "E" is used for ENTER/EXIT prints
-- (*) "B" is used for BANNER prints
-- (*) DEBUG is used for larger structure content dumps.
-- ======================================================================
local GP;     -- Global Print Instrument
local F=false; -- Set F (flag) to true to turn ON global print
local E=false; -- Set E (ENTER/EXIT) to true to turn ON Enter/Exit print
local B=false; -- Set B (Banners) to true to turn ON Banner Print
local GD;     -- Global Debug Instrument
local DEBUG=false; -- turn on for more elaborate state dumps.

-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- <<  LSET Main Functions >>
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- The following external functions are defined in the LSET module:
--
-- (*) Status = lset.add( topRec, ldtBinName, newValue, userModule, src)
-- (*) Status = lset.add_all( topRec, ldtBinName, valueList, userModule, src)
-- (*) Object = lset.get( topRec, ldtBinName, searchValue, src) 
-- (*) Number = lset.exists( topRec, ldtBinName, searchValue, src) 
-- (*) List   = lset.scan( topRec, ldtBinName, userModule, filter, fargs, src)
-- (*) Status = lset.remove( topRec, ldtBinName, searchValue, src) 
-- (*) Object = lset.take( topRec, ldtBinName, searchValue, src) 
-- (*) Status = lset.destroy( topRec, ldtBinName, src)
-- (*) Number = lset.size( topRec, ldtBinName )
-- (*) Map    = lset.get_config( topRec, ldtBinName )
-- (*) Status = lset.set_capacity( topRec, ldtBinName, new_capacity)
-- (*) Status = lset.get_capacity( topRec, ldtBinName )
-- ======================================================================

-- Large Set Design/Architecture
--
-- Large Set includes two different implementations in the same module.
-- The implementation used is determined by the setting "SetTypeStore"
-- in the LDT control structure.  There are the following choices.
-- (1) "TopRecord" SetTypeStore, which holds all data in the top record.
--     This is appropriate for small to medium lists only, as the total
--     storage capacity is limited to the max size of a record, which 
--     defaults to 128kb, but can be upped to 2mb (or even more?)
-- (2) "SubRecord" SetTypeStore, which holds data in sub-records.  With
--     the sub-record type, Large Sets can be virtually any size, although
--     the digest directory in the TopRecord can potentially grow large 
--     for VERY large sets.
--
-- The LDT bin value in a top record, known as "ldtCtrl" (LDT Control),
-- is a list of two maps.  The first map is the property map, and is the
-- same for every LDT.  It is done this way so that the LDT code in
-- the Aerospike Server can read any LDT property using the same mechanism.
-- ======================================================================
-- >> Please refer to ldt/doc_lset.md for architecture and design notes.
-- ======================================================================
--
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- LSET Visual Depiction
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- There are two different implementations of Large Set:
-- (1) TopRecord Mode (the first one to be implemented)
-- (2) SubRecord Mode
--
-- ++=================++
-- || TOP RECORD MODE ||
-- ++=================++
-- In a user record, the bin holding the Large SET control information
-- is named with the user's name, however, there is a restriction that there
-- can be only ONE "TopRecord Mode" LSET instance in a record.  This
-- restriction exists because of the way the numbered bins are used in the
-- record.  The Numbered LSETS bins each contain a list of entries. They
-- are prefixed with "LSetBin_" and numbered from 0 to N, where N is the
-- modulo value that is set on create (otherwise, default to 31).
--
-- When an LDT instance is created in a record, a hidden "LDT Properties" bin
-- is created in the record.  There is only ONE LDT Prop bin per record, no
-- matter how many LDT instances are in the record.
--
-- In the bin named by the user for the LSET LDT instance, (e.g. MyURLs)
-- there is an "LDT Control" structure, which is a list of two maps.
-- The first map, the Property Map, holds the same information for every
-- LDT (stack, list, map, set).  The second map holds LSET-specific 
-- information.
--
-- (Standard Mode)
-- +-----+-----+-----+-----+----------------------------------------+
-- |User |User | LDT |LSET |LSET |LSET |. . .|LSET |                |
-- |Bin 1|Bin 2| Prop|CTRL |Bin 0|Bin 1|     |Bin N|                |
-- +-----+-----+-----+-----+----------------------------------------+
--                      |     |     |           |                   
--                      V     V     V           V                   
--                   +=====++===+ +===+       +===+                  
--                   |P Map||val| |val|       |val|
--                   +-----+|val| |val|       |val|
--                   |C Map||...| |...|       |...|
--                   +=====+|val| |val|       |val|
--                          +===+ +===+       +===+ 
--
-- The Large Set distributes searches over N lists.  Searches are done
-- with linear scan in one of the bin lists.  The set values are hashed
-- and then the specific bin is picked "hash(val) Modulo N".  The N bins
-- are organized by name using the method:  prefix "LsetBin_" and the
-- modulo N number.
--
-- The modulo number is always a prime number -- to minimize the amount
-- of "collisions" that are often found in power of two modulo numbers.
-- Common choices are 17, 31 and 61.
--
-- The initial state of the LSET is "Compact Mode", which means that ONLY
-- ONE LIST IS USED -- in Bin 0.  Once there are a "Threshold Number" of
-- entries, the Bin 0 entries are rehashed into the full set of bin lists.
-- Note that a more general implementation could keep growing, using one
-- of the standard "Linear Hashing-style" growth patterns.
--
-- (Compact Mode)
-- +-----+-----+-----+-----+----------------------------------------+
-- |User |User | LDT |LSET |LSET |LSET |. . .|LSET |                |
-- |Bin 1|Bin 2| Prop|CTRL |Bin 0|Bin 1|     |Bin N|                |
-- +-----+-----+-----+-----+----------------------------------------+
--                      |     |   
--                      V     V  
--                   +=====++===+
--                   |P Map||val|
--                   +-----+|val|
--                   |C Map||...|
--                   +=====+|val|
--                          +===+
-- ++=================++
-- || SUB RECORD MODE ||
-- ++=================++
--
-- (Standard Mode)
-- +-----+-----+-----+-----+-----+
-- |User |User | LDT |LSET |User |
-- |Bin 1|Bin 2| Prop|CTRL |Bin N|
-- +-----+-----+-----+-----+-----+
--                      |    
--                      V    
--                   +======+
--                   |P Map |
--                   +------+
--                   |C Map |
--                   +------+
--                   |@|@||@| Hash Cell Anchors (Control + Digest List)
--                   +|=|=+|+
--                    | |  |                       SubRec N
--                    | |  +--------------------=>+--------+
--                    | |              SubRec 2   |Entry 1 |
--                    | +------------=>+--------+ |Entry 2 |
--                    |      SubRec 1  |Entry 1 | |   o    |
--                    +---=>+--------+ |Entry 2 | |   o    |
--                          |Entry 1 | |   o    | |   o    |
--                          |Entry 2 | |   o    | |Entry n |
--                          |   o    | |   o    | +--------+
--                          |   o    | |Entry n |
--                          |   o    | +--------+
--                          |Entry n | "LDR" (LDT Data Record) Pages
--                          +--------+ hold the actual data entries
--
-- The Hash Directory actually has a bit more structure than just a 
-- digest list. The Hash Directory is a list of "Cell Anchors" that
-- contain several pieces of information.
-- A Cell Anchor maintains a count of the subrecords attached to a
-- a hash directory entry.  Furthermore, if there are more than one
-- subrecord associated with a hash cell entry, then we basically use
-- the hash value to further distribute the values across multiple
-- sub-records.
--
--  +-------------+
-- [[ Cell Anchor ]]
--  +-------------+
-- Cell Item Count: Total number of items in this hash cell
-- Cell SubRec Count: Number of sub-records associated with this hash cell
-- Cell SubRec Depth: Depth (modulo) of the rehash (1, 2, 4, 8 ...)
-- Cell Digest Map: The association of a hash depth value to a digest
-- Cell Item List: If in "bin compact mode", the list of elements.
--
-- ======================================================================
-- Aerospike Server Functions:
-- The following functions are used to manipulate TopRecords and
-- SubRecords.
-- ======================================================================
-- Aerospike Record Functions:
-- status = aerospike:create( topRec )
-- status = aerospike:update( topRec )
-- status = aerospike:remove( rec ) (not currently used)
--
--
-- Aerospike SubRecord Functions:
-- newRec = aerospike:create_subrec( topRec )
-- rec    = aerospike:open_subrec( topRec, childRecDigest)
-- status = aerospike:update_subrec( childRec )
-- status = aerospike:close_subrec( childRec )
-- status = aerospike:remove_subrec( subRec )  
--
-- Record Functions:
-- digest = record.digest( childRec )
-- status = record.set_type( topRec, recType )
-- status = record.set_flags( topRec, binName, binFlags )
-- ======================================================================
--
-- ++==================++
-- || External Modules ||
-- ++==================++
-- set up our "outside" links.
-- We use this to get our Hash Functions
local  CRC32 = require('ldt/CRC32');

-- We use this to get access to all of the Functions
local functionTable = require('ldt/UdfFunctionTable');

-- We import all of our error codes from "ldt_errors.lua" and we access
-- them by prefixing them with "ldte.XXXX", so for example, an internal error
-- return looks like this:
-- error( ldte.ERR_INTERNAL );
local ldte = require('ldt/ldt_errors');

-- We have a set of packaged settings for each LDT.
local lsetPackage = require('ldt/settings_lset');

-- We have recently moved a number of COMMON functions into the "ldt_common"
-- module, namely the subrec routines and some list management routines.
-- We will likely move some other functions in there as they become common.
local ldt_common = require('ldt/ldt_common');

-- ++=======================================++
-- || GLOBAL VALUES -- Local to this module ||
-- ++=======================================++
-- This flavor of LDT (only LSET defined here)
local LDT_TYPE_LSET   = "LSET";

-- AS_BOOLEAN TYPE:
-- There are apparently either storage or conversion problems with booleans
-- and Lua and Aerospike, so rather than STORE a Lua Boolean value in the
-- LDT Control map, we're instead going to store an AS_BOOLEAN value, which
-- is a character (defined here).  We're using Characters rather than
-- numbers (0, 1) because a character takes ONE byte and a number takes EIGHT
local AS_TRUE='T';
local AS_FALSE='F';

-- =======================================================================
-- NOTE: It is important that the next values stay consistent
-- with the same variables in the ldt/settings_lset.lua file.
-- ===========================================================<Begin>=====
-- In this early version of SET, we distribute values among lists that we
-- keep in the top record.  This is the default modulo value for that list
-- distribution.
local DEFAULT_MODULO = 128;

-- Switch from a single list to distributed lists after this amount
local DEFAULT_THRESHOLD = 20;

-- Switch from a SMALL list in the cell anchor to a full Sub-Rec.
local DEFAULT_BINLIST_THRESHOLD = 4;

-- Define the default value for the "Unique Identifier" function.
-- User can override the function name, if they so choose.
local UI_FUNCTION_DEFAULT = "unique_identifier";
--
-- ===========================================================<End>=======

-- Use this to test for CtrlMap Integrity.  Every map should have one.
local MAGIC="MAGIC";     -- the magic value for Testing LSET integrity

-- StoreMode (SM) values (which storage Mode are we using?)
local SM_BINARY  ='B'; -- Using a Transform function to compact values
local SM_LIST    ='L'; -- Using regular "list" mode for storing values.

-- StoreState (SS) values (which "state" is the set in?)
local SS_COMPACT ='C'; -- Using "single bin" (compact) mode
local SS_REGULAR ='R'; -- Using "Regular Storage" (regular) mode

-- KeyType (KT) values
local KT_ATOMIC  ='A'; -- the set value is just atomic (number or string)
local KT_COMPLEX ='C'; -- the set value is complex. Use Function to get key.

-- Hash Value (HV) Constants
local HV_EMPTY = 'E'; -- Marks an Entry Hash Directory Entry.

-- Bin Flag Types -- to show the various types of bins.
-- NOTE: All bins will be labelled as either (1:RESTRICTED OR 2:HIDDEN)
-- We will not currently be using "Control" -- that is effectively HIDDEN
local BF_LDT_BIN     = 1; -- Main LDT Bin (Restricted)
local BF_LDT_HIDDEN  = 2; -- LDT Bin::Set the Hidden Flag on this bin
local BF_LDT_CONTROL = 4; -- Main LDT Control Bin (one per record)
--
-- HashType (HT) values
local HT_STATIC  ='S'; -- Use a FIXED set of bins for hash lists
local HT_DYNAMIC ='D'; -- Use a DYNAMIC set of bins for hash lists

-- SetTypeStore (ST) values
local ST_RECORD = 'R'; -- Store values (lists) directly in the Top Record
local ST_SUBRECORD = 'S'; -- Store values (lists) in Sub-Records
local ST_HYBRID = 'H'; -- Store values (lists) Hybrid Style
-- NOTE: Hybrid style means that we'll use sub-records, but for any hash
-- value that is less than "SUBRECORD_THRESHOLD", we'll store the value(s)
-- in the top record.  It is likely that very short lists will waste a lot
-- of sub-record storage. Although, storage in the top record also costs
-- in terms of the read/write of the top record.

-- Key Compare Function for Complex Objects
-- By default, a complex object will have a "key" field, which the
-- key_compare() function will use to compare.  If the user passes in
-- something else, then we'll use THAT to perform the compare, which
-- MUST return -1, 0 or 1 for A < B, A == B, A > B.
-- UNLESS we are using a simple true/false equals compare.
-- ========================================================================
-- Actually -- the default will be EQUALS.  The >=< functions will be used
-- in the Ordered LIST implementation, not in the simple list implementation.
-- ========================================================================
local KC_DEFAULT="keyCompareEqual"; -- Key Compare used only in complex mode
local KH_DEFAULT="keyHash";         -- Key Hash used only in complex mode

-- AS LSET Bin Names
-- local LSET_CONTROL_BIN       = "LSetCtrlBin";
local LSET_CONTROL_BIN       = "DO NOT USE";
local LSET_DATA_BIN_PREFIX   = "LSetBin_";

-- Enhancements for LSET begin here 

-- Record Types -- Must be numbers, even though we are eventually passing
-- in just a "char" (and int8_t).
-- NOTE: We are using these vars for TWO purposes -- and I hope that doesn't
-- come back to bite me.
-- (1) As a flag in record.set_type() -- where the index bits need to show
--     the TYPE of record (CDIR NOT used in this context)
-- (2) As a TYPE in our own propMap[PM_RecType] field: CDIR *IS* used here.
local RT_REG = 0; -- 0x0: Regular Record (Here only for completeneness)
local RT_LDT = 1; -- 0x1: Top Record (contains an LDT)
local RT_SUB = 2; -- 0x2: Regular Sub Record (LDR, CDIR, etc)
local RT_CDIR= 3; -- xxx: Cold Dir Subrec::Not used for set_type() 
local RT_ESR = 4; -- 0x4: Existence Sub Record

-- Errors used in LDT Land, but errors returned to the user are taken
-- from the common error module: ldt_errors.lua
local ERR_OK            =  0; -- HEY HEY!!  Success
local ERR_GENERAL       = -1; -- General Error
local ERR_NOT_FOUND     = -2; -- Search Error

-- -----------------------------------------------------------------------
---- ------------------------------------------------------------------------
-- Note:  All variables that are field names will be upper case.
-- It is EXTREMELY IMPORTANT that these field names ALL have unique char
-- values. (There's no secret message hidden in these values).
-- Note that we've tried to make the mapping somewhat cannonical where
-- possible. 
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Record Level Property Map (RPM) Fields: One RPM per record
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Fields common across lset, lstack & lmap 
local RPM_LdtCount             = 'C';  -- Number of LDTs in this rec
local RPM_VInfo                = 'V';  -- Partition Version Info
local RPM_Magic                = 'Z';  -- Special Sauce
local RPM_SelfDigest           = 'D';  -- Digest of this record

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- LDT specific Property Map (PM) Fields: One PM per LDT bin:
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Fields common for all LDT's
local PM_ItemCount             = 'I'; -- (Top): Count of all items in LDT
local PM_Version               = 'V'; -- (Top): Code Version
local PM_SubRecCount           = 'S'; -- (Top): # of subRecs in the LDT
local PM_LdtType               = 'T'; -- (Top): Type: stack, set, map, list
local PM_BinName               = 'B'; -- (Top): LDT Bin Name
local PM_Magic                 = 'Z'; -- (All): Special Sauce
local PM_CreateTime			   = 'C'; -- (Top): LDT Create Time
local PM_EsrDigest             = 'E'; -- (All): Digest of ESR
local PM_RecType               = 'R'; -- (All): Type of Rec:Top,Ldr,Esr,CDir
local PM_LogInfo               = 'L'; -- (All): Log Info (currently unused)
local PM_ParentDigest          = 'P'; -- (Subrec): Digest of TopRec
local PM_SelfDigest            = 'D'; -- (Subrec): Digest of THIS Record

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Main LDT Map Field Name Mapping
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- Fields Common to ALL LDTs (managed by the LDT COMMON routines)
local M_UserModule             = 'P'; -- User's Lua file for overrides
local M_KeyFunction            = 'F'; -- User Supplied Key Extract Function
local M_KeyType                = 'k'; -- Key Type: Atomic or Complex
local M_StoreMode              = 'M'; -- SM_LIST or SM_BINARY
local M_StoreLimit             = 'L'; -- Used for Eviction (eventually)
local M_Transform              = 't'; -- Transform object to Binary form
local M_UnTransform            = 'u'; -- UnTransform object from Binary form

-- Fields unique to lset & lmap 
local M_LdrEntryCountMax       = 'e'; -- Max size of the LDR List
local M_LdrByteEntrySize       = 's'; -- Size of a Fixed Byte Object
local M_LdrByteCountMax        = 'b'; -- Max Size of the LDR in bytes
local M_StoreState             = 'S'; -- Store State (Compact or List)
local M_SetTypeStore           = 'T'; -- Type of the Set Store (Rec/SubRec)
local M_HashType               = 'h'; -- Hash Type (static or dynamic)
local M_BinaryStoreSize        = 'B'; -- Size of Object when in Binary form
local M_TotalCount             = 'C'; -- Total number of slots used
local M_Modulo 				   = 'm'; -- Modulo used for Hash Function
local M_ThreshHold             = 'H'; -- Threshold: Compact->Regular state
local M_CompactList            = 'c'; -- Compact List (when in Compact Mode)
local M_HashDirectory          = 'D'; -- Directory of Hash Cells
local M_HashCellMaxList        = 'X'; -- Threshold for converting from a
                                      -- local binlist to sub-record.
-- ------------------------------------------------------------------------
-- Maintain the LSET letter Mapping here, so that we never have a name
-- collision: Obviously -- only one name can be associated with a character.
-- We won't need to do this for the smaller maps, as we can see by simple
-- inspection that we haven't reused a character.
-- ------------------------------------------------------------------------
---- >>> Be Mindful of the LDT Common Fields that ALL LDTs must share <<<
-- ------------------------------------------------------------------------
-- A:                         a:                         0:
-- B:M_BinaryStoreSize        b:M_LdrByteCountMax        1:
-- C:M_TotalCount             c:M_CompactList            2:
-- D:M_HashDirectory          d:                         3:
-- E:                         e:M_LdrEntryCountMax       4:
-- F:M_KeyFunction            f:                         5:
-- G:                         g:                         6:
-- H:M_Threshold              h:M_HashType               7:
-- I:                         i:                         8:
-- J:                         j:                         9:
-- K:                         k:M_KeyType
-- L:M_StoreLimit             l:
-- M:M_StoreMode              m:M_Modulo
-- N:                         n:
-- O:                         o:
-- P:M_UserModule             p:
-- Q:                         q:
-- R:                         r:                     
-- S:M_StoreState             s:M_LdrByteEntrySize   
-- T:M_SetTypeStore           t:M_Transform
-- U:                         u:M_UnTransform
-- V:                         v:
-- W:                         w:                     
-- X:M_HashCellMaxList        x:                     
-- Y:                         y:
-- Z:                         z:
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- We won't bother with the sorted alphabet mapping for the rest of these
-- fields -- they are so small that we should be able to stick with visual
-- inspection to make sure that nothing overlaps.  And, note that these
-- Variable/Char mappings need to be unique ONLY per map -- not globally.
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- ------------------------------------------------------------------------
-- For the Sub-Record version of Large Set, we store the values for a
-- particular hash cell in one or more sub-records.  For a given modulo
-- (directory size) value, we allocate a small object that holds the anchor
-- for one or more sub-records that hold values.
-- ------------------------------------------------------------------------
-- ++==================++
-- || Hash Cell Anchor ||
-- ++==================++
local X_ItemCount              = 'I'; -- Number of items for this dir cell
local X_SubRecordCount         = 'S'; -- Number of sub recs for this dir cell
local X_DigestList             = 'D'; -- Head of the Sub-Rec list
local X_ValueList              = 'V'; -- Value list (if not a Sub-Rec list)


-- -----------------------------------------------------------------------
-- Currently in transition from old Hash Cell Anchor (X_...) to new
-- Hash Cell Anchor (C_...) notation.
-- -----------------------------------------------------------------------
-- Cell Anchors are used in both LSET and LMAP.  They use the same Hash
-- Directory structure and Hash Cell structure, except that LSET uses a
-- SINGLE value list and LMAP uses two lists (Name, Value).
-- -----------------------------------------------------------------------
-- Cell Anchor Fields:  A cell anchor is a map object that sits in each
-- cell of the hash directory.   Since we don't have the freedom of keeping
-- NULL array entries (as one might in C), we have to keep an active object
-- in the Hash Directory list, otherwise, a NULL (nil) entry would actually
-- crash in message pack (or, somewhere).
--
-- A Hash Cell can be in one of FOUR states:
-- (1) C_EMPTY: just the CellState has a value.
-- (2) C_LIST: a small list of objects is anchored to this cell.
-- (3) C_DIGEST: A SINGLE DIGEST value points to a single sub-record.
-- (4) C_TREE: A Tree Root points to a set of Sub-Records
-- -----------------------------------------------------------------------
-- Here are the fields used in a Hash Cell Anchor
local C_CellState      = 'S'; -- Hold the Cell State
-- local C_CellNameList   = 'N'; -- Pt to a LIST of objects (not for LSET)
local C_CellValueList  = 'V'; -- Pt to a LIST of objects
local C_CellDigest     = 'D'; -- Pt to a single digest value
local C_CellTree       = 'T'; -- Pt to a LIST of digests

-- Here are the various constants used with Hash Cells
local C_STATE_EMPTY   = 'E'; -- 
local C_STATE_LIST    = 'L';
local C_STATE_DIGEST  = 'D';
local C_STATE_TREE    = 'T';
-- -----------------------------------------------------------------------
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- LDT Data Record (LDR) Control Map Fields (Recall that each Map ALSO has
-- the PM (general property map) fields.
local LDR_ByteEntryCount       = 'C'; -- Count of bytes used (in binary mode)
local LDR_NextSubRecDigest     = 'N'; -- Digest of Next Subrec in the chain

-- ++====================++
-- || INTERNAL BIN NAMES || -- Local, but global to this module
-- ++====================++
-- The Top Rec LDT bin is named by the user -- so there's no hardcoded name
-- for each used LDT bin.
--
-- In the main record, there is one special hardcoded bin -- that holds
-- some shared information for all LDTs.
-- Note the 14 character limit on Aerospike Bin Names.
-- >> (14 char name limit) 12345678901234 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
local REC_LDT_CTRL_BIN  = "LDTCONTROLBIN"; -- Single bin for all LDT in rec

-- There are TWO different types of (Child) sub-records that are associated
-- with an LSET LDT:
-- (1) LDR (LDT Data Record) -- used to hold data from the Hash Cells
-- (2) Existence Sub Record (ESR) -- Ties all children to a parent LDT
-- Each Subrecord has some specific hardcoded names that are used
--
-- All LDT sub-records have a properties bin that holds a map that defines
-- the specifics of the record and the LDT.
-- NOTE: Even the TopRec has a property map -- but it's stashed in the
-- user-named LDT Bin
-- >> (14 char name limit) 12345678901234 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
local SUBREC_PROP_BIN   = "SR_PROP_BIN";
--
-- The LDT Data Records (LDRs) use the following bins:
-- The SUBREC_PROP_BIN mentioned above, plus
-- >> (14 char name limit) 12345678901234 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
local LDR_CTRL_BIN      = "LdrControlBin";  
local LDR_LIST_BIN      = "LdrListBin";  
local LDR_BNRY_BIN      = "LdrBinaryBin";

-- Enhancements for LSET end here 

-- ======================================================================
-- <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS>
-- ======================================================================
-- We have several different situations where we need to look up a user
-- defined function:
-- (*) Object Transformation (e.g. compression)
-- (*) Object UnTransformation
-- (*) Predicate Filter (perform additional predicate tests on an object)
--
-- These functions are passed in by name (UDF name, Module Name), so we
-- must check the existence/validity of the module and UDF each time we
-- want to use them.  Furthermore, we want to centralize the UDF checking
-- into one place -- so on entry to those LDT functions that might employ
-- these UDFs (e.g. insert, filter), we'll set up either READ UDFs or
-- WRITE UDFs and then the inner routines can call them if they are
-- non-nil.
-- ======================================================================
local G_Filter = nil;
local G_Transform = nil;
local G_UnTransform = nil;
local G_FunctionArgs = nil;
local G_KeyFunction = nil;

-- Special Function -- if supplied by the user in the "userModule", then
-- we call that UDF to adjust the LDT configuration settings.
local G_SETTINGS = "adjust_settings";

-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 
-- -----------------------------------------------------------------------
-- resetPtrs()
-- -----------------------------------------------------------------------
-- Reset the UDF Ptrs to nil.
-- -----------------------------------------------------------------------
local function resetUdfPtrs()
  G_Filter = nil;
  G_Transform = nil;
  G_UnTransform = nil;
  G_FunctionArgs = nil;
  G_KeyFunction = nil;
end -- resetPtrs()

-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 
-- <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> <udf> 

-- ======================================================================
-- <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS> - <USER FUNCTIONS>
-- ======================================================================

-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- AS Large Set Utility Functions
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

-- ======================================================================
-- createSearchPath: Create and initialize a search path structure so
-- that we can fill it in during our hash chain search.
-- Parms:
-- (*) ldtMap: topRec map that holds all of the control values
-- ======================================================================
local function createSearchPath( ldtMap )
  local sp        = map();
  sp.FoundLevel   = 0;      -- No valid level until we find something
  sp.LevelCount   = 0;      -- The number of levels we looked at.
  sp.RecList      = list(); -- Track all open nodes in the path
  sp.DigestList   = list(); -- The mechanism to open each level
  sp.PositionList = list(); -- Remember where the key was
  sp.HasRoom      = list(); -- Remember where there is room.

  return sp;
end -- createSearchPath()

-- ======================================================================
-- adjustLdtMap:
-- ======================================================================
-- Using the settings supplied by the caller in the stackCreate call,
-- we adjust the values in the ldtMap.
-- Parms:
-- (*) ldtMap: the main LSET Bin value
-- (*) argListMap: Map of LSET Settings 
-- ======================================================================
local function adjustLdtMap( ldtMap, argListMap )
  local meth = "adjustLdtMap()";
  GP=E and trace("[ENTER]: <%s:%s>:: LSetMap(%s)::\n ArgListMap(%s)",
    MOD, meth, tostring(ldtMap), tostring( argListMap ));

  -- Iterate thru the argListMap and adjust (override) the map settings 
  -- based on the settings passed in during the create() call.
  GP=F and trace("[DEBUG]: <%s:%s> : Processing Arguments:(%s)",
    MOD, meth, tostring(argListMap));

  -- For the old style -- we'd iterate thru ALL arguments and change
  -- many settings.  Now we process only packages this way.
  for name, value in map.pairs( argListMap ) do
    GP=F and trace("[DEBUG]: <%s:%s> : Processing Arg: Name(%s) Val(%s)",
        MOD, meth, tostring( name ), tostring( value ));

    -- Process our "prepackaged" settings.  These now reside in the
    -- settings file.  All of the packages are in a table, and thus are
    -- looked up dynamically.
    -- Notice that this is the old way to change settings.  The new way is
    -- to use a "user module", which contains UDFs that control LDT settings.
    if name == "Package" and type( value ) == "string" then
      local ldtPackage = lsetPackage[value];
      if( ldtPackage ~= nil ) then
        ldtPackage( ldtMap );
      end
    end
  end -- for each argument

  GP=E and trace("[EXIT]: <%s:%s> : CTRL Map after Adjust(%s)",
    MOD, meth , tostring(ldtMap));
      
  return ldtMap;
end -- adjustLdtMap

-- ======================================================================
-- propMapSummary( resultMap, propMap )
-- ======================================================================
-- Add the propMap properties to the supplied resultMap.
-- ======================================================================
local function propMapSummary( resultMap, propMap )
  -- Fields common for all LDT's
  resultMap.PropItemCount        = propMap[PM_ItemCount];
  resultMap.PropVersion          = propMap[PM_Version];
  resultMap.PropSubRecCount      = propMap[PM_SubRecCount];
  resultMap.PropLdtType          = propMap[PM_LdtType];
  resultMap.PropBinName          = propMap[PM_BinName];
  resultMap.PropMagic            = propMap[PM_Magic];
  resultMap.CreateTime           = propMap[PM_CreateTime];
  resultMap.PropEsrDigest        = propMap[PM_EsrDigest];
  resultMap.RecType              = propMap[PM_RecType];
  resultMap.ParentDigest         = propMap[PM_ParentDigest];
  resultMap.SelfDigest           = propMap[PM_SelfDigest];
end -- function propMapSummary()

-- ======================================================================
-- ldtMapSummary( resultMap, ldtMap )
-- ======================================================================
-- Add the ldtMap properties to the supplied resultMap.
-- ======================================================================
local function ldtMapSummary( resultMap, ldtMap )
  
    -- LDT Data Record Chunk Settings:
  resultMap.LdrEntryCountMax     = ldtMap[M_LdrEntryCountMax];
  resultMap.LdrByteEntrySize     = ldtMap[M_LdrByteEntrySize];
  resultMap.LdrByteCountMax      = ldtMap[M_LdrByteCountMax];
  
  -- General LDT Parms:
  resultMap.StoreMode            = ldtMap[M_StoreMode];
  resultMap.StoreState           = ldtMap[M_StoreState];
  resultMap.SetTypeStore         = ldtMap[M_SetTypeStore];
  resultMap.StoreLimit           = ldtMap[M_StoreLimit];
  resultMap.Transform            = ldtMap[M_Transform];
  resultMap.UnTransform          = ldtMap[M_UnTransform];
  resultMap.UserModule           = ldtMap[M_UserModule];
  resultMap.BinaryStoreSize      = ldtMap[M_BinaryStoreSize];
  resultMap.KeyType              = ldtMap[M_KeyType];
  resultMap.TotalCount			 = ldtMap[M_TotalCount];		
  resultMap.Modulo 				 = ldtMap[M_Modulo];
  resultMap.ThreshHold			 = ldtMap[M_ThreshHold];

end -- function ldtMapSummary

-- ======================================================================
-- ldtDebugDump()
-- ======================================================================
-- To aid in debugging, dump the entire contents of the ldtCtrl object
-- for LMAP.  Note that this must be done in several prints, as the
-- information is too big for a single print (it gets truncated).
-- ======================================================================
local function ldtDebugDump( ldtCtrl )
  -- Print MOST of the "TopRecord" contents of this LMAP object.
  local resultMap                = map();
  resultMap.SUMMARY              = "LMAP Summary";

  info("\n\n <><><><><><><><><> [ LDT LMAP SUMMARY ] <><><><><><><><><> \n");
  --
  if ( ldtCtrl == nil ) then
    warn("[ERROR]: <%s:%s>: EMPTY LDT BIN VALUE", MOD, meth);
    resultMap.ERROR =  "EMPTY LDT BIN VALUE";
    info("<<<%s>>>", tostring(resultMap));
    return 0;
  end

  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  if( propMap[PM_Magic] ~= MAGIC ) then
    resultMap.ERROR =  "BROKEN MAP--No Magic";
    info("<<<%s>>>", tostring(resultMap));
    return 0;
  end;

  -- Load the common properties
  propMapSummary( resultMap, propMap );
  info("\n<<<%s>>>\n", tostring(resultMap));
  resultMap = nil;

  -- Reset for each section, otherwise the result would be too much for
  -- the info call to process, and the information would be truncated.
  resultMap2 = map();
  resultMap2.SUMMARY              = "LMAP-SPECIFIC Values";

  -- Load the LMAP-specific properties
  ldtMapSummary( resultMap2, ldtMap );
  info("\n<<<%s>>>\n", tostring(resultMap2));
  resultMap2 = nil;

  -- Print the Hash Directory
  resultMap3 = map();
  resultMap3.SUMMARY              = "LMAP Hash Directory";
  resultMap3.HashDirectory        = ldtMap[M_HashDirectory];
  info("\n<<<%s>>>\n", tostring(resultMap3));

end -- function ldtDebugDump()

-- ======================================================================
-- local function ldtSummary( ldtCtrl ) (DEBUG/Trace Function)
-- ======================================================================
-- For easier debugging and tracing, we will summarize the ldtMap
-- contents -- without printing out the entire thing -- and return it
-- as a string that can be printed.
-- ======================================================================
local function ldtSummary( ldtCtrl )

  if ( ldtCtrl == nil ) then
    warn("[ERROR]: <%s:%s>: EMPTY LDT BIN VALUE", MOD, meth);
    return "EMPTY LDT BIN VALUE";
  end

  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  
  if( propMap[PM_Magic] ~= MAGIC ) then
    return "BROKEN MAP--No Magic";
  end;

  -- Return a map to the caller, with descriptive field names
  local resultMap                = map();
  resultMap.SUMMARY              = "LSET Summary";

  -- Load up the COMMON properties
  propMapSummary( resultMap, propMap );

  -- Load up the LSET specific properties:
  ldtMapSummary( resultMap, ldtMap );

  return resultMap;
end -- ldtSummary()

-- ======================================================================
-- local function ldtSummaryString( ldtCtrl ) (DEBUG/Trace Function)
-- ======================================================================
-- For easier debugging and tracing, we will summarize the ldtMap
-- contents -- without printing out the entire thing -- and return it
-- as a string that can be printed.
-- ======================================================================
local function ldtSummaryString( ldtCtrl )
   GP=F and trace("Calling ldtSummaryString "); 
  return tostring( ldtSummary( ldtCtrl ));
end -- ldtSummaryString()

-- ======================================================================
-- initializeLdtCtrl:
-- ======================================================================
-- Set up the LSetMap with the standard (default) values.
-- These values may later be overridden by the user.
-- The structure held in the Record's "LSetBIN" is this map.  This single
-- structure contains ALL of the settings/parameters that drive the LSet
-- behavior.
-- Parms:
-- (*) topRec: The Aerospike Server record on which we operate
-- (*) namespace: The Namespace of the record (topRec)
-- (*) set: The Set of the record (topRec)
-- (*) ldtBinName: The name of the bin for the AS Large Set
-- (*) distrib: The Distribution Factor (how many separate bins) 
-- Return: The initialized ldtMap.
-- It is the job of the caller to store in the rec bin and call update()
-- ======================================================================
local function initializeLdtCtrl(topRec, ldtBinName )
  local meth = "initializeLdtCtrl()";
  GP=E and trace("[ENTER]: <%s:%s>::Bin(%s)",MOD, meth, tostring(ldtBinName));
  
  -- Create the two maps and fill them in.  There's the General Property Map
  -- and the LDT specific LDT Map.
  -- Note: All Field Names start with UPPER CASE.
  local propMap = map();
  local ldtMap = map();
  local ldtCtrl = list();

  -- General LDT Parms(Same for all LDTs): Held in the Property Map
  propMap[PM_ItemCount] = 0; -- A count of all items in the stack
  propMap[PM_SubRecCount] = 0; -- A count of all Sub-Records in the LDT
  propMap[PM_Version]    = G_LDT_VERSION ; -- Current version of the code
  propMap[PM_LdtType]    = LDT_TYPE_LSET; -- Validate the ldt type
  propMap[PM_Magic]      = MAGIC; -- Special Validation
  propMap[PM_BinName]    = ldtBinName; -- Defines the LDT Bin
  propMap[PM_RecType]    = RT_LDT; -- Record Type LDT Top Rec
  propMap[PM_EsrDigest]  = nil; -- not set yet.
  propMap[PM_CreateTime] = aerospike:get_current_time();

  -- Specific LSET Parms: Held in ldtMap
  ldtMap[M_StoreMode]   = SM_LIST; -- SM_LIST or SM_BINARY:
  ldtMap[M_StoreLimit]  = 0; -- No storage Limit

  -- LDT Data Record Chunk Settings: Passed into "Chunk Create"
  ldtMap[M_LdrEntryCountMax]= 100;  -- Max # of Data Chunk items (List Mode)
  ldtMap[M_LdrByteEntrySize]=   0;  -- Byte size of a fixed size Byte Entry
  ldtMap[M_LdrByteCountMax] =   0; -- Max # of Data Chunk Bytes (binary mode)

  ldtMap[M_Transform]        = nil; -- applies only to complex objects
  ldtMap[M_UnTransform]      = nil; -- applies only to complex objects
  ldtMap[M_StoreState]       = SS_COMPACT; -- SM_LIST or SM_BINARY:

  -- ===================================================
  -- NOTE: We will leave the DEFAULT LSET implementation as TOP_RECORD,
  -- but at some point (when it is mature), we may wan to switch the default
  -- to the SUB-RECORD implementation. (10/21/13 tjl)
  -- Temporarily Switched over manually for testing
  -- ===================================================
  ldtMap[M_SetTypeStore]     = ST_RECORD; -- default is Top Record Store.
--ldtMap[M_SetTypeStore]     = ST_SUBRECORD; -- Optional: Use Subrecords

  ldtMap[M_HashType]         = HT_STATIC; -- Static or Dynamic
  ldtMap[M_BinaryStoreSize]  = nil; 
  -- Complex will work for both atomic/complex.
  ldtMap[M_KeyType]          = KT_COMPLEX; -- Most things will be complex
  ldtMap[M_TotalCount]       = 0; -- Count of both valid and deleted elements
  ldtMap[M_Modulo]           = DEFAULT_MODULO;
  ldtMap[M_ThreshHold]       = 101; -- Rehash after this many inserts
  ldtMap[M_HashCellMaxList]  = 4; -- Threshold for converting from a

  -- Put our new maps in a list, in the record, then store the record.
  list.append( ldtCtrl, propMap );
  list.append( ldtCtrl, ldtMap );
  topRec[ldtBinName]            = ldtCtrl;
  record.set_flags( topRec, ldtBinName, BF_LDT_BIN ); -- must set every time

  GP=F and trace("[DEBUG]: <%s:%s> : LSET Summary after Init(%s)",
      MOD, meth , ldtSummaryString(ldtCtrl));

  -- If the topRec already has an LDT CONTROL BIN (with a valid map in it),
  -- then we know that the main LDT record type has already been set.
  -- Otherwise, we should set it. This function will check, and if necessary,
  -- set the control bin.
  -- This method will also call record.set_type().
  ldt_common.setLdtRecordType( topRec );

  GP=E and trace("[EXIT]:<%s:%s>:", MOD, meth );
  return ldtCtrl;

end -- initializeLdtCtrl()

-- ======================================================================
-- We use the "CRC32" package for hashing the value in order to distribute
-- the value to the appropriate "sub lists".
-- ======================================================================
-- local  CRC32 = require('ldt/CRC32'); Do this above, in the "global" area
-- ======================================================================
-- Return the hash of "value", with modulo.
-- Notice that we can use ZERO, because this is not an array index
-- (which would be ONE-based for Lua) but is just used as a name.
-- ======================================================================
local function old_stringHash( value, modulo )
  if value ~= nil and type(value) == "string" then
    return CRC32.Hash( value ) % modulo;
  else
    return 0;
  end
end -- stringHash

-- ======================================================================
-- Return the hash of "value", with modulo
-- Notice that we can use ZERO, because this is not an array index
-- (which would be ONE-based for Lua) but is just used as a name.
-- NOTE: Use a better Hash Function.
-- ======================================================================
local function old_numberHash( value, modulo )
  local meth = "numberHash()";
  local result = 0;
  if value ~= nil and type(value) == "number" then
    -- math.randomseed( value ); return math.random( modulo );
    result = CRC32.Hash( value ) % modulo;
  end
  GP=E and trace("[EXIT]:<%s:%s>HashResult(%s)", MOD, meth, tostring(result))
  return result
end -- numberHash

-- ======================================================================
-- local  CRC32 = require('CRC32'); Do this above, in the "global" area
-- ======================================================================
-- Return the hash of "value", with modulo.
-- Notice that we can use ZERO, because this is not an array index
-- (which would be ONE-based for Lua) but is just used as a name.
-- ======================================================================
local function stringHash( value, modulo )
  local meth = "stringHash()";
  GP=E and trace("[ENTER]<%s:%s> val(%s) Mod = %s", MOD, meth,
  tostring(value), tostring(modulo));

  local result = 0;
  if value ~= nil and type(value) == "string" then
    result = CRC32.Hash( value ) % modulo;
  end
  GP=E and trace("[EXIT]:<%s:%s>HashResult(%s)", MOD, meth, tostring(result));
  return result;
end -- stringHash()

-- ======================================================================
-- Return the hash of "value", with modulo
-- Notice that we can use ZERO, because this is not an array index
-- (which would be ONE-based for Lua) but is just used as a name.
-- NOTE: Use a better Hash Function.
-- ======================================================================
local function numberHash( value, modulo )
  local meth = "numberHash()";
  GP=E and trace("[ENTER]<%s:%s> val(%s) Mod = %s", MOD, meth,
    tostring(value), tostring(modulo));

  local result = 0;
  if value ~= nil and type(value) == "number" then
    result = CRC32.Hash( value ) % modulo;
  end
  GP=E and trace("[EXIT]:<%s:%s>HashResult(%s)", MOD, meth, tostring(result));
  return result;
end -- numberHash()

-- ======================================================================
-- Get (create) a unique bin name given the current counter.
-- 'LSetBin_XX' will be the individual bins that hold lists of set data
-- ======================================================================
local function getBinName( number )
  local binPrefix = "LSetBin_";
  return binPrefix .. tostring( number );
end

-- ======================================================================
-- setupNewBin: Initialize a new bin -- (the thing that holds a list
-- of user values).  If this is the FIRST bin (zero), then it is really
-- the CompactList, although that looks like a regular list.
-- Parms:
-- (*) topRec
-- (*) Bin Number
-- Return: New Bin Name
-- ======================================================================
local function setupNewBin( topRec, binNum )
  local meth = "setupNewBin()";
  GP=E and trace("[ENTER]: <%s:%s> Bin(%d) ", MOD, meth, binNum );

  local binName = getBinName( binNum );
  -- create the first LSetBin_n LDT bin
  topRec[binName] = list(); -- Create a new list for this new bin

  -- This bin must now be considered HIDDEN:
  GP=E and trace("[DEBUG]: <%s:%s> Setting BinName(%s) as HIDDEN",
                 MOD, meth, binName );
  record.set_flags(topRec, binName, BF_LDT_HIDDEN ); -- special bin

  GP=E and trace("[EXIT]: <%s:%s> BinNum(%d) BinName(%s)",
                 MOD, meth, binNum, binName );

  return binName;
end -- setupNewBin

-- ======================================================================
-- Produce a COMPARABLE value (our overloaded term here is "key") from
-- the user's value.
-- The value is either simple (atomic) or an object (complex).  Complex
-- objects either have a key function defined, or we produce a comparable
-- "keyValue" from "value" by performing a tostring() operation.
--
-- NOTE: According to Chris (yes, everybody hates Chris), the tostring()
-- method will ALWAYS create the same string for complex objects that
-- have the same value.  We've noticed that tostring() does not always
-- show maps with fields in the same order, but in theory two objects (maps)
-- with the same content will have the same tostring() value.
-- Parms:
-- (*) ldtMap: The basic LDT Control structure
-- (*) value: The value from which we extract a compare-able "keyValue".
-- Return a comparable value:
-- ==> The original value, if it is an atomic type
-- ==> A Unique Identifier subset (that is atomic)
-- ==> The entire object, in string form.
-- ======================================================================
local function getKeyValue( ldtMap, value )
  local meth = "getKeyValue()";
  GP=E and trace("[ENTER]<%s:%s> value(%s) KeyType(%s)",
    MOD, meth, tostring(value), tostring(ldtMap[M_KeyType]) );

  if( value == nil ) then 
    GP=E and trace("[Early EXIT]<%s:%s> Value is nil", MOD, meth );
    return nil;
  end

  GP=E and trace("[DEBUG]<%s:%s> Value type(%s)", MOD, meth,
    tostring( type(value)));

  local keyValue;
  -- This test looks bad.  Let's just base our decision on the value
  -- that is in front of us.
  -- if( ldtMap[M_KeyType] == KT_ATOMIC or type(value) ~= "userdata" ) then
  if( type(value) == "number" or type(value) == "string" ) then
    keyValue = value;
  else
    -- Now, we assume type is "userdata".
    if( G_KeyFunction ~= nil ) then
      -- Employ the user's supplied function (keyFunction).
      keyValue = G_KeyFunction( value );
    else
      -- If there's no shortcut, then take the "longcut" to get an atomic
      -- value that represents this entire object.
      keyValue = tostring( value );
    end
  end

  GP=E and trace("[EXIT]<%s:%s> Result(%s)", MOD, meth, tostring(keyValue) );
  return keyValue;
end -- getKeyValue();

-- ======================================================================
-- Change this to use the "standard" Hash -- computeHashCell() -- that is
-- used by both LSET and LMAP.
-- ======================================================================
-- computeSetBin()
-- Find the right bin for this value.
-- First -- know if we're in "compact" StoreState or "regular" 
-- StoreState.  In compact mode, we ALWAYS look in the single bin.
-- Second -- use the right hash function (depending on the type).
-- NOTE that we should be passed in ONLY KEYS, not objects, so we don't
-- need to do  "Key Extract" here, regardless of whether we're doing
-- ATOMIC or COMPLEX Object values.
-- ======================================================================
local function computeSetBin( key, ldtMap )
  local meth = "computeSetBin()";
  GP=E and trace("[ENTER]: <%s:%s> val(%s) Map(%s) ",
                 MOD, meth, tostring(key), tostring(ldtMap) );

  -- Check StoreState:  If we're in single bin mode, it's easy. Everything
  -- goes to Bin ZERO.
  -- Otherwise, Hash the key value, assuming it's either a number or a string.
  local binNumber  = 0; -- Default, if COMPACT mode
  if ldtMap[M_StoreState] == SS_REGULAR then
    -- There are really only TWO primitive types that we can handle,
    -- and that is NUMBER and STRING.  Anything else is just wrong!!
    if type(key) == "number" then
      binNumber  = numberHash( key, ldtMap[M_Modulo] );
    elseif type(key) == "string" then
      binNumber  = stringHash( key, ldtMap[M_Modulo] );
    else
      warn("[INTERNAL ERROR]<%s:%s>Hash(%s) requires type number or string!",
        MOD, meth, type(key) );
      error( ldte.ERR_INTERNAL );
    end
  end

  GP=E and trace("[EXIT]: <%s:%s> Key(%s) BinNumber (%d) ",
                 MOD, meth, tostring(key), binNumber );

  return binNumber;
end -- computeSetBin()

-- ======================================================================
-- listAppend()
-- ======================================================================
-- General tool to append one list to another.   At the point that we
-- find a better/cheaper way to do this, then we change THIS method and
-- all of the LDT calls to handle lists will get better as well.
-- ======================================================================
local function listAppend( baseList, additionalList )
  if( baseList == nil ) then
    warn("[INTERNAL ERROR] Null baselist in listAppend()" );
    error( ldte.ERR_INTERNAL );
  end
  local listSize = list.size( additionalList );
  for i = 1, listSize, 1 do
    list.append( baseList, additionalList[i] );
  end -- for each element of additionalList

  return baseList;
end -- listAppend()

-- =======================================================================
-- subRecSummary()
-- =======================================================================
-- Show the basic parts of the sub-record contents.  Make sure that this
-- isn't nil or equal to ZERO before extracing fields.
-- Return a Summary Map that shows the value.
-- =======================================================================
local function subRecSummary( subrec )
  local resultMap = map();
  if( subrec == nil ) then
    resultMap.SubRecSummary = "NIL SUBREC";
  elseif( type(subrec) == "number" and subrec == 0 ) then
    resultMap.SubRecSummary = "NOT a SUBREC (ZERO)";
  else
    resultMap.SubRecSummary = "Regular SubRec";

    local propMap  = subrec[SUBREC_PROP_BIN];
    local ctrlMap  = subrec[LDT_CTRL_BIN];
    local valueList  = subrec[LDR_LIST_BIN];

    -- General Properties (the Properties Bin)
    resultMap.SUMMARY           = "NODE Summary";
    resultMap.PropMagic         = propMap[PM_Magic];
    resultMap.PropCreateTime    = propMap[PM_CreateTime];
    resultMap.PropEsrDigest     = propMap[PM_EsrDigest];
    resultMap.PropRecordType    = propMap[PM_RecType];
    resultMap.PropParentDigest  = propMap[PM_ParentDigest];
    
    resultMap.ControlMap = ctrlMap;
    resultMap.ValueList = valueList;
  end
  
  return resultMap;
  
end -- subRecSummary()

-- =======================================================================
-- cellAnchorDump()
-- =======================================================================
-- Dump the contents of a hash cell.
-- The cellAnchor is either "EMPTY" or it has a valid Cell Anchor structure.
-- First, check type (string) and value (HC_EMPTY) to see if nothing is
-- here.  Notice that this means that we have to init the hashDir correctly
-- when we create it.
-- =======================================================================
local function cellAnchorDump( src, topRec, cellAnchor )
  local meth = "cellAnchorDump()";
  GP=E and trace("[ENTER]<%s:%s> src(%s)", MOD, meth, tostring(src));

  local resultMap = map();

  if( cellAnchor ~= nil ) then
    resultMap.Summary = "NIL CELL ANCHOR";
  elseif( type(cellAnchor) == "string" and cellAnchor == HV_EMPTY ) then
    resultMap.Summary = "EMPTY CELL ANCHOR";
  else
    if( cellAnchor[X_SubRecordCount] == 0 ) then
      -- Read the List
      resultMap.Summary = "CELL ANCHOR: List";
      local valueList = cellAnchor[X_ValueList];
      if( valueList == nil ) then
        resultMap.ValueList = "EMPTY LIST";
      else
        resultMap.ValueList = valueList;
      end
    else
      -- Ok -- so we have sub-records.  Get the subrec, then search the list.
      local digestList = cellAnchor[X_DigestList];
      local listSize = list.size( digestList );
      for i = 0, listSize, 1 do
        local digestString = tostring( digestList[i] );
        -- local subRec = aerospike:open_subrec( topRec, digestString );
        local subRec =
            ldt_common.openSubRec( src, topRec, digestString );
        resultMap[i] = subRecSummary( subrec );
        aerospike:close_subrec(subrec);
      end -- for()
    end -- subrec case
  end -- cellAnchor case

  GP=E and trace("[EXIT]<%s:%s>ResultMap(%s)",MOD,meth,tostring(resultMap));
  return resultMap;

end -- cellAnchorDump()

-- =======================================================================
-- searchList()
-- =======================================================================
-- Search a list for an item.  Each object (atomic or complex) is translated
-- into a "searchKey".  That can be a hash, a tostring or any other result
-- of a "uniqueIdentifier()" function.
--
-- (*) ldtMap: Main LDT Control Structure
-- (*) binList: the list of values from the record
-- (*) searchKey: the "translated value"  we're searching for
-- Return the position if found, else return ZERO.
-- =======================================================================
local function searchList(ldtMap, binList, searchKey )
  local meth = "searchList()";
  GP=E and trace("[ENTER]: <%s:%s> Looking for searchKey(%s) in List(%s)",
     MOD, meth, tostring(searchKey), tostring(binList));
                 
  local position = 0; 

  -- Nothing to search if the list is null or empty
  if( binList == nil or list.size( binList ) == 0 ) then
    GP=F and trace("[DEBUG]<%s:%s> EmptyList", MOD, meth );
    return 0;
  end

  -- Search the list for the item (searchKey) return the position if found.
  -- Note that searchKey may be the entire object, or it may be a subset.
  local listSize = list.size(binList);
  local item;
  local dbKey;
  for i = 1, listSize, 1 do
    item = binList[i];
    GP=F and trace("[COMPARE]<%s:%s> index(%d) SV(%s) and ListVal(%s)",
                   MOD, meth, i, tostring(searchKey), tostring(item));
    -- a value that does not exist, will have a nil binList item
    -- so we'll skip this if-loop for it completely                  
    if item ~= nil then
      if( G_UnTransform ~= nil ) then
        modValue = G_UnTransform( item );
      else
        modValue = item;
      end
      -- Get a "compare" version of the object.  This is either a summary
      -- piece, or just a "tostring()" of the entire object.
      dbKey = getKeyValue( ldtMap, modValue );
      GP=F and trace("[ACTUAL COMPARE]<%s:%s> index(%d) SV(%s) and dbKey(%s)",
                   MOD, meth, i, tostring(searchKey), tostring(dbKey));
      if(dbKey ~= nil and type(searchKey) == type(dbKey) and searchKey == dbKey)
      then
        position = i;
        GP=F and trace("[FOUND!!]<%s:%s> index(%d) SV(%s) and dbKey(%s)",
                   MOD, meth, i, tostring(searchKey), tostring(dbKey));
        break;
      end
    end -- end if not null and not empty
  end -- end for each item in the list

  GP=E and trace("[EXIT]<%s:%s> Result: Position(%d)", MOD, meth, position );
  return position;
end -- searchList()

-- =======================================================================
-- topRecScan()
-- =======================================================================
-- Scan a List, append all the items in the list to result if they pass
-- the filter.
-- Parms:
-- (*) topRec:
-- (*) resultList: List holding search result
-- (*) ldtCtrl: The main LDT control structure
-- Return: resultlist 
-- =======================================================================
local function topRecScan( topRec, ldtCtrl, resultList )
  local meth = "topRecScan()";
  GP=E and trace("[ENTER]: <%s:%s> Scan all TopRec elements", MOD, meth );

  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];
  local listCount = 0;
  local liveObject = nil; -- the live object after "UnTransform"
  local resultFiltered = nil;

  -- Loop through all the modulo n lset-record bins 
  local distrib = ldtMap[M_Modulo];
  GP=F and trace(" Number of LSet bins to parse: %d ", distrib)
  for j = 0, (distrib - 1), 1 do
	local binName = getBinName( j );
    GP=F and trace(" Parsing through :%s ", tostring(binName))
	if topRec[binName] ~= nil then
      local objList = topRec[binName];
      if( objList ~= nil ) then
        for i = 1, list.size( objList ), 1 do
          if objList[i] ~= nil then
            if G_UnTransform ~= nil then
              liveObject = G_UnTransform( objList[i] );
            else
              liveObject = objList[i]; 
            end
            -- APPLY FILTER HERE, if we have one.  If no filter, then pass
            -- the value thru.
            if G_Filter ~= nil then
              resultFiltered = G_Filter( liveObject, G_FunctionArgs );
            else
              resultFiltered = liveObject;
            end
            list.append( resultList, resultFiltered );
          end -- end if not null and not empty
  		end -- end for each item in the list
      end -- if bin list not nil
    end -- end of topRec null check 
  end -- end for distrib list for-loop 

  GP=E and trace("[EXIT]: <%s:%s> Appending %d elements to ResultList ",
                 MOD, meth, list.size(resultList));

  -- Return list passed back via "resultList".
  return 0; 
end -- topRecScan


-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Perform the "regular" scan -- a scan of the hash directory that will
-- mostly contain pointers to Sub-Records.
-- Parms:
-- (*) topRec:
-- (*) resultList: List holding search result
-- (*) ldtCtrl: The main LDT control structure
-- Return: resultlist 
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
local function subRecScan( src, topRec, ldtCtrl, resultList )
  local meth = "subRecScan()";
  GP=E and trace("[ENTER]: <%s:%s> Scan all SubRec elements", MOD, meth );

  -- For each cell in the Hash Directory, extract that Cell and scan
  -- its contents.  The contents of a cell may be:
  -- (*) EMPTY
  -- (*) A Pair of Short Name/Value lists
  -- (*) A SubRec digest
  -- (*) A Radix Tree of multiple SubRecords
  local ldtMap = ldtCtrl[2];
  local hashDir = ldtMap[M_HashDirectory];
  local cellAnchor;

  local hashDirSize = list.size( hashDir );

  for i = 1, hashDirSize,  1 do
    cellAnchor = hashDir[i];
    if( cellAnchor ~= nil and cellAnchor[C_CellState] ~= C_STATE_EMPTY ) then

      GD=DEBUG and trace("[DEBUG]<%s:%s>\nHash Cell :: Index(%d) Cell(%s)",
        MOD, meth, i, tostring(cellAnchor));

      -- If not empty, then the cell anchor must be either in an empty
      -- state, or it has a Sub-Record.  Later, it might have a Radix tree
      -- of multiple Sub-Records.
      if( cellAnchor[C_CellState] == C_STATE_LIST ) then
        -- The small list is inside of the cell anchor.  Get the lists.
        scanList( cellAnchor[C_CellValueList], resultList );
      elseif( cellAnchor[C_CellState] == C_STATE_DIGEST ) then
        -- We have a sub-rec -- open it
        local digest = cellAnchor[C_CellDigest];
        if( digest == nil ) then
          warn("[ERROR]: <%s:%s>: nil Digest value",  MOD, meth );
          error( ldte.ERR_SUBREC_OPEN );
        end

        local digestString = tostring(digest);
        local subRec = ldt_common.openSubRec( src, topRec, digestString );
        if( subRec == nil ) then
          warn("[ERROR]: <%s:%s>: subRec nil or empty: Digest(%s)",  MOD, meth,
            digestString );
          error( ldte.ERR_SUBREC_OPEN );
        end
        scanList( subRec[LDR_LIST_BIN], resultList );
        ldt_common.closeSubRec( src, subRec, false);
      else
        -- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        -- When we do a Radix Tree, we will STILL end up with a SubRecord
        -- but it will come from a Tree.  We just need to manage the SubRec
        -- correctly.
        warn("[ERROR]<%s:%s> Not yet ready to handle Radix Trees in Hash Cell",
          MOD, meth );
        error( ldte.ERR_INTERNAL );
        -- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      end
    end
  end -- for each Hash Dir Cell

  GP=E and trace("[EXIT]: <%s:%s> Appended %d elements to ResultList ",
                 MOD, meth, #resultList );

  return 0; 
end -- subRecScan

-- ======================================================================
-- localTopRecInsert()
-- ======================================================================
-- Perform the main work of insert (used by both rehash and insert)
-- Parms:
-- (*) topRec: The top DB Record:
-- (*) ldtCtrl: The LSet control map
-- (*) newValue: Value to be inserted
-- (*) stats: 1=Please update Counts, 0=Do NOT update counts (rehash)
-- RETURN:
--  0: ok
-- -1: Unique Value violation
-- ======================================================================
local function localTopRecInsert( topRec, ldtCtrl, newValue, stats )
  local meth = "localTopRecInsert()";
  
  GP=E and trace("[ENTER]:<%s:%s>value(%s) stats(%s) ldtCtrl(%s)",
    MOD, meth, tostring(newValue), tostring(stats), ldtSummaryString(ldtCtrl));

  local propMap = ldtCtrl[1];  
  local ldtMap = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];
  local rc = 0;
  
  -- We'll get the key and use that to feed to the hash function, which will
  -- tell us what bin we're in.
  local key = getKeyValue( ldtMap, newValue );
  local binNumber = computeSetBin( key, ldtMap );
  local binName = getBinName( binNumber );
  local binList = topRec[binName];
  
  -- We're doing "Lazy Insert", so if a bin is not there, then we have not
  -- had any values for that bin (yet).  Allocate the list now.
  if binList == nil then
    GP=F and trace("[DEBUG]:<%s:%s> Creating List for binName(%s)",
                 MOD, meth, tostring( binName ) );
    binList = list();
  else
    -- Look for the value, and insert if it is not there.
    local position = searchList( ldtMap, binList, key );
    if( position > 0 ) then
      info("[ERROR]<%s:%s> Attempt to insert duplicate value(%s)",
        MOD, meth, tostring( newValue ));
      error(ldte.ERR_UNIQUE_KEY);
    end
  end
  -- If we have a transform, apply it now and store the transformed value.
  local storeValue = newValue;
  if( G_Transform ~= nil ) then
    storeValue = G_Transform( newValue );
  end
  list.append( binList, storeValue );

  topRec[binName] = binList; 
  record.set_flags(topRec, binName, BF_LDT_HIDDEN );--Must set every time

  -- Update stats if appropriate.
  if( stats == 1 ) then -- Update Stats if success
    local itemCount = propMap[PM_ItemCount];
    local totalCount = ldtMap[M_TotalCount];
    
    propMap[PM_ItemCount] = itemCount + 1; -- number of valid items goes up
    ldtMap[M_TotalCount] = totalCount + 1; -- Total number of items goes up
    topRec[ldtBinName] = ldtCtrl;
    record.set_flags(topRec,ldtBinName,BF_LDT_BIN);--Must set every time

    GP=F and trace("[STATUS]<%s:%s>Updating Stats TC(%d) IC(%d) Val(%s)",
      MOD, meth, ldtMap[M_TotalCount], propMap[PM_ItemCount], 
        tostring( newValue ));
  else
    GP=F and trace("[STATUS]<%s:%s>NOT updating stats(%d)",MOD,meth,stats);
  end

  GP=E and trace("[EXIT]<%s:%s>Insert Results: RC(%d) Value(%s) binList(%s)",
    MOD, meth, rc, tostring( newValue ), tostring(binList));

  return rc;
end -- localTopRecInsert()

-- ======================================================================
-- topRecRehashSet()
-- ======================================================================
-- When we start in "compact" StoreState (SS_COMPACT), we eventually have
-- to switch to "regular" state when we get enough values.  So, at some
-- point (StoreThreshold), we rehash all of the values in the single
-- bin and properly store them in their final resting bins.
-- So -- copy out all of the items from bin 1, null out the bin, and
-- then resinsert them using "regular" mode.
-- Parms:
-- (*) topRec
-- (*) ldtCtrl
-- ======================================================================
local function topRecRehashSet( topRec, ldtCtrl )
  local meth = "topRecRehashSet()";
  GP=E and trace("[ENTER]:<%s:%s> !!!! REHASH !!!! ", MOD, meth );
  GP=E and trace("[ENTER]:<%s:%s> LDT CTRL(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl));

  local propMap = ldtCtrl[1];  
  local ldtMap = ldtCtrl[2];

  -- Get the list, make a copy, then iterate thru it, re-inserting each one.
  local singleBinName = getBinName( 0 );
  local singleBinList = topRec[singleBinName];
  if singleBinList == nil then
    warn("[INTERNAL ERROR]:<%s:%s> Rehash can't use Empty Bin (%s) list",
         MOD, meth, tostring(singleBinName));
    error( ldte.ERR_INSERT );
  end
  local listCopy = list.take( singleBinList, list.size( singleBinList ));
  topRec[singleBinName] = nil; -- this will be reset shortly.
  ldtMap[M_StoreState] = SS_REGULAR; -- now in "regular" (modulo) mode
  
  -- Rebuild. Allocate new lists for all of the bins, then re-insert.
  -- Create ALL of the new bins, each with an empty list
  -- Our "indexing" starts with ZERO, to match the modulo arithmetic.
  local distrib = ldtMap[M_Modulo];
  for i = 0, (distrib - 1), 1 do
    -- assign a new list to topRec[binName]
    setupNewBin( topRec, i );
  end -- for each new bin

  for i = 1, list.size(listCopy), 1 do
    localTopRecInsert(topRec,ldtCtrl,listCopy[i],0); -- do NOT update counts.
  end

  GP=E and trace("[EXIT]: <%s:%s>", MOD, meth );
end -- topRecRehashSet()

-- ======================================================================
-- initializeSubRec()
-- Set up a Hash Sub-Record 
-- There are potentially FOUR bins in a Sub-Record:
-- (0) nodeRec[SUBREC_PROP_BIN]: The Property Map
-- (1) nodeRec[LSR_CTRL_BIN]:   The control Map (defined here)
-- (2) nodeRec[LSR_LIST_BIN]:   The Data Entry List (when in list mode)
-- (3) nodeRec[LSR_BINARY_BIN]: The Packed Data Bytes (when in Binary mode)
-- Pages are either in "List" mode or "Binary" mode (the whole LDT value is in
-- one mode or the other), so the record will employ only three fields.
-- Either Bins 0,1,2 or Bins 0,1,3.
-- Parms:
-- (*) topRec
-- (*) ldtCtrl
-- (*) subRec
-- ======================================================================
local function initializeSubRec( topRec, ldtCtrl, subRec )
  local meth = "initializeSubRec()";
  GP=E and trace("[ENTER]:<%s:%s> ", MOD, meth );

  local topDigest = record.digest( topRec );
  local subRecDigest = record.digest( subRec );
  
  -- Extract the property map and control map from the ldt bin list.
  local topPropMap = ldtCtrl[1];
  local topLdtMap  = ldtCtrl[2];

  -- NOTE: Use Top level LDT entry for mode and max values
  --
  -- Set up the LDR Property Map
  subRecPropMap = map();
  subRecPropMap[PM_Magic] = MAGIC;
  subRecPropMap[PM_EsrDigest] = topPropMap[PM_EsrDigest]; 
  subRecPropMap[PM_RecType] = RT_SUB;
  subRecPropMap[PM_ParentDigest] = topDigest;
  subRecPropMap[PM_SelfDigest] = subRecDigest;
  -- For sub-recs, set create time to ZERO.
  subRecPropMap[PM_CreateTime] = 0;

  -- Set up the LDR Control Map
  subRecLdtMap = map();

  -- Depending on the StoreMode, we initialize the control map for either
  -- LIST MODE, or BINARY MODE
  if( topLdtMap[R_StoreMode] == SM_LIST ) then
    -- List Mode
    GP=F and trace("[DEBUG]: <%s:%s> Initialize in LIST mode", MOD, meth );
    subRecLdtMap[LF_ByteEntryCount] = 0;
    -- If we have an initial value, then enter that in our new object list.
    -- Otherwise, create an empty list.
    local objectList = list();
    if( firstValue ~= nil ) then
      list.append( objectList, firstValue );
      subRecLdtMap[LF_ListEntryCount] = 1;
      subRecLdtMap[LF_ListEntryTotal] = 1;
    else
      subRecLdtMap[LF_ListEntryCount] = 0;
      subRecLdtMap[LF_ListEntryTotal] = 0;
    end
    subRec[LSR_LIST_BIN] = objectList;
  else
    -- Binary Mode
    GP=F and trace("[DEBUG]: <%s:%s> Initialize in BINARY mode", MOD, meth );
    warn("[WARNING!!!]<%s:%s>Not ready for BINARY MODE YET!!!!", MOD, meth );
    subRecLdtMap[LF_ListEntryTotal] = 0;
    subRecLdtMap[LF_ListEntryCount] = 0;
    subRecLdtMap[LF_ByteEntryCount] = 0;
  end

  -- Take our new structures and put them in the subRec record.
  subRec[SUBREC_PROP_BIN] = subRecPropMap;
  subRec[LSR_CTRL_BIN] = subRecLdtMap;
  -- We must tell the system what type of record this is (sub-record)
  -- NOTE: No longer needed.  This is handled in the ldt setup.
  -- record.set_type( subRec, RT_SUB );

  aerospike:update_subrec( subRec );
  -- Note that the caller will write out the record, since there will
  -- possibly be more to do (like add data values to the object list).
  GP=F and trace("[DEBUG]<%s:%s> TopRec Digest(%s) subRec Digest(%s))",
    MOD, meth, tostring(topDigest), tostring(subRecDigest));

  GP=F and trace("[DEBUG]<%s:%s> subRecPropMap(%s) subRec Map(%s)",
    MOD, meth, tostring(subRecPropMap), tostring(subRecLdtMap));

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return rc;
end -- initializeSubRec()

-- ======================================================================
-- subRecSearch()
-- ======================================================================
-- Search the contents of this cellAnchor.
-- Parms:
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- (*) topRec: Top Record (main aerospike record)
-- (*) ldtCtrl: Main LDT Control Structure.
-- (*) key: The value (or subvalue) that we're searching for.
-- Return: 
-- Successful operation:
-- ==> Found in Subrec:  {position, subRecPtr}
-- ==> Found in ValueList:  {position, 0}
-- ==> NOT Found:  {0, subRecPtr}
-- Extreme Error -- longjump out
-- ======================================================================
local function subRecSearch( src, topRec, ldtCtrl, key )
  local meth = "subRecSearch()";
  
  GP=E and trace("[ENTER]:<%s:%s>Digest(%s) SearchVal(%s)",
    MOD, meth, digestString, tostring(key));
    
  local valueList;
  local position = 0;
  local rc = 0;
  local subrec = 0;

  if( cellAnchor[X_SubRecordCount] == 0 ) then
    -- Do a List Search
    valueList = cellAnchor[X_ValueList];
    if( valueList ~= nil ) then
      -- Search the list.  Return position if found.
      position = searchList( ldtMap, valueList, key );
    end
    return position, 0;
  else
    -- Ok -- so we have sub-records.  Get the subrec, then search the list.
    -- For NOW -- we will have ONLY ONE digest in the list.  Later, we'll
    -- go with a list (for cell fan-out).
    
    -- Init our subrecContext, if necessary.  The SRC tracks all open
    -- SubRecords during the call. Then, allows us to close them all at the end.
    -- For the case of repeated calls from Lua, the caller must pass in
    -- an existing SRC that lives across LDT calls.
    if ( src == nil ) then
      src = ldt_common.createSubRecContext();
    end

    local digestList = cellAnchor[X_DigestList];
    -- SPECIAL CASE :: ONLY ONE DIGEST FOR NOW.
    --
    local digestString = tostring( digestList[1] );
    subrec  = ldt_common.openSubRec( src, toprec, digestString );
    valueList = subrec[LDR_LIST_BIN];
    if( valueList == nil ) then
      warn("[INTERNAL ERROR]<%s:%s> Cell Anchor ValueList NIL", MOD, meth );
      error( ldte.ERR_INTERNAL );
    end

    position = searchList( ldtMap, valueList, key );
  end

  GP=E and trace("[EXIT]<%s:%s>Search Results: Pos(%d) SubRec Summary(%s)",
    MOD, meth, position, tostring(subRecSummary(subrec)) );

  return position, subrec;
end -- subRecSearch()

-- ======================================================================
-- topRecSearch
-- ======================================================================
-- In Top Record Mode,
-- Find an element (i.e. search), and optionally apply a filter.
-- Return the element if found, return an error (NOT FOUND) otherwise
-- Parms:
-- (*) topRec: Top Record -- needed to access numbered bins
-- (*) ldtCtrl: the main LDT Control structure
-- (*) searchKey: This is the value we're looking for.
-- NOTE: We've now switched to using a different mode for the filter
-- and the "UnTransform" function.  We set that up once on entry into
-- the search function (using the new lookup mechanism involving user
-- modules).
-- Return: The Found Object, or Error (not found)
-- ======================================================================
local function topRecSearch( topRec, ldtCtrl, searchKey )
  local meth = "topRecSearch()";
  GP=E and trace("[ENTER]: <%s:%s> Search Key(%s)",
                 MOD, meth, tostring( searchKey ) );

  local rc = 0; -- Start out ok.

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- Find the appropriate bin for the Search value
  local binNumber = computeSetBin( searchKey, ldtMap );
  local binName = getBinName( binNumber );
  local binList = topRec[binName];
  local liveObject = nil;
  local resultFitlered = nil;
  local position = 0;

  GP=F and trace("[DEBUG]<%s:%s> UnTrans(%s) Filter(%s) SrchKey(%s) List(%s)",
    MOD, meth, tostring(G_UnTransform), tostring( G_Filter),
    tostring(searchKey), tostring(binList));

  -- We bother to search only if there's a real list.
  if binList ~= nil and list.size( binList ) > 0 then
    position = searchList( ldtMap, binList, searchKey );
    if( position > 0 ) then
      -- Apply the filter to see if this item qualifies
      -- First -- we have to untransform it (sadly, again)
      local item = binList[position];
      if G_UnTransform ~= nil then
        liveObject = G_UnTransform( item );
      else
        liveObject = item;
      end

      -- APPLY FILTER HERE, if we have one.
      if G_Filter ~= nil then
        resultFiltered = G_Filter( liveObject, G_FunctionArgs );
      else
        resultFiltered = liveObject;
      end
    end -- if search found something (pos > 0)
  end -- if there's a list

  if( resultFiltered == nil ) then
    warn("[WARNING]<%s:%s> Value not found: Value(%s)",
      MOD, meth, tostring( searchKey ) );
    error( ldte.ERR_NOT_FOUND );
  end

  GP=E and trace("[EXIT]: <%s:%s>: Success: SearchKey(%s) Result(%s)",
     MOD, meth, tostring(searchKey), tostring( resultFiltered ));
  return resultFiltered;
end -- function topRecSearch()

-- ======================================================================
-- newCellAnchor()
-- ======================================================================
-- Perform an insert into a NEW Cell Anchor.
-- A Cell Anchor starts in the following state:
-- (*) A local List (something small)
-- Parms:
-- (*) newValue: Value to be inserted
-- RETURN:
--  New cellAnchor.
-- ======================================================================
local function newCellAnchor( newValue )
  local meth = "newCellAnchor()";
  
  GP=E and trace("[ENTER]:<%s:%s> Value(%s) ", MOD, meth, tostring(newValue));
  
  local cellAnchor = map();
  local valueList = list();
  list.append( valueList, newValue );
  cellAnchor[X_ValueList] = valueList;
  cellAnchor[X_ItemCount] = 1;
  cellAnchor[X_SubRecordCount] = 0;
  
  return cellAnchor;
end -- newCellAnchor()


-- ======================================================================
-- createHashSubRec() Create a new Hash Cell Sub-Rec and initialize it.
-- ======================================================================
-- Create and initialize the Sub-Rec for Hash.
-- All LDT sub-records have a properties bin that holds a map that defines
-- the specifics of the record and the LDT.
-- >> (14 char name limit) 12345678901234 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
local SUBREC_PROP_BIN   = "SR_PROP_BIN";
--
-- The LDT Data Records (LDRs) use the following bins:
-- The SUBREC_PROP_BIN mentioned above, plus
-- >> (14 char name limit) 12345678901234 <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
local LDR_CTRL_BIN      = "LdrControlBin";  
local LDR_LIST_BIN      = "LdrListBin";  
local LDR_BNRY_BIN      = "LdrBinaryBin";
-- ======================================================================
-- Parms:
-- (*) src: subrecContext: The pool of open subrecords
-- (*) topRec: The main AS Record holding the LDT
-- (*) ldtCtrl: Main LDT Control Structure
-- Contents of a Node Record:
-- (1) SUBREC_PROP_BIN: Main record Properties go here
-- (2) LDR_CTRL_BIN:    Main Node Control structure
-- (3) LDR_LIST_BIN:    Value List goes here
-- (4) LDR_BNRY_BIN:    Packed Binary Array (if used) goes here
-- ======================================================================
local function createHashSubRec( src, topRec, ldtCtrl )
  local meth = "createHashSubRec()";
  GP=E and trace("[ENTER]<%s:%s> ", MOD, meth );

  -- Extract the property map and control map from the ldt bin list.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- Create the Aerospike Sub-Record, initialize the Bins (Ctrl, List).
  -- The ldt_common.createSubRec() handles the record type and the SRC.
  -- It also kicks out with an error if something goes wrong.
  local subRec = ldt_common.createSubRec( src, topRec, ldtCtrl, RT_SUB );
  local ldrPropMap = subRec[SUBREC_PROP_BIN];
  local ldrCtrlMap = map();

  -- Set up the Sub-Rec Ctrl Map - Still not sure what's in here.
  -- ldrCtrlMap[???] = 0;

  -- Store the new maps in the record.
  -- subRec[SUBREC_PROP_BIN] = ldrPropMap;
  subRec[LDR_CTRL_BIN]    = ldrCtrlMap;
  subRec[LDR_LIST_BIN] = list(); -- Holds the Items
  -- subRec[LDR_BNRY_BIN] = nil; -- not used (yet)

  -- NOTE: The SubRec business is Handled by subRecCreate().
  -- Also, If we had BINARY MODE working for inner nodes, we would initialize
  -- the Key BYTE ARRAY here.

  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return nodeSubRec;
end -- createHashSubRec()


-- ======================================================================
-- cellAnchorInsert()
-- ======================================================================
-- Perform an insert into an existing Cell Anchor.
-- A Cell Anchor may be in one of the following states:
-- (*) A local List (something small)
-- (*) A single SubRec
-- (*) Multiple Subrecs.
-- Parms:
-- (*) src: The sub-rec context
-- (*) topRec: The top DB Record:
-- (*) ldtCtrl: The LDT Control Structure
-- (*) key: The value to search for
-- (*) newValue: Value to be inserted
-- RETURN:
--  0: ok
-- -1: Unique Value violation
-- ======================================================================
local function cellAnchorInsert( src, topRec, ldtCtrl, key, newValue )
  local meth = "cellAnchorInsert()";
  
  GP=E and trace("[ENTER]:<%s:%s> Key(%s) Value(%s) ldtMap(%s)", MOD, meth,
    tostring(key), tostring(newValue), tostring(ldtMap));
  
  local propMap = ldtCtrl[1];  
  local ldtMap = ldtCtrl[2];

  -- See which state the cellAnchor is in: (List, SingleSubRec, MultiSubRec).
  -- If the sub-rec count is zero, then there's only a list present.
  local valueList;
  local position;
  local subRec
  local rc = 0;
  if( cellAnchor[X_SubRecordCount] == 0 ) then
    -- We are in LIST MODE:  Do a List Search and List Insert
    valueList = cellAnchor[X_ValueList];
    if( valueList == nil ) then
      valueList = list();
      list.append( valueList, newValue );
      return 0;  -- All is well
    end
    -- Search the list.  If found complain, if not, append.
    -- If we get a viable candidate, then we have to check for rehash before
    -- we can do the insert.
    position = searchList( ldtMap, valueList, key );
    if( position > 0 ) then
      warn("[UNIQUE ERROR]<%s:%s> Position(%d) searchKey(%s)",
        MOD, meth, position, tostring(key));
      error( ldte.ERR_UNIQUE_KEY );
    end

    -- You'd think that either size mechanism would work: #valueList or
    -- list.size(valueList), but apparently #valueList doesn't reliably
    -- return the correct size.  TODO: Fix that later.
    local valueListSize = list.size(valueList);
    if( valueListSize < ldtMap[M_ThreshHold] ) then
      -- No worries, append to the list and leave. Otherwise, we drop
      -- down into the Sub-Record case.
      list.append( valueList, newValue );
      -- All is well.
      return 0;
    end
    -- Create A Sub-Rec and drop into Sub-Rec section below.
    subRec = ldt_common.createSubRec( src, topRec, ldtCtrl, RT_SUB );
    list.append( valueList, newValue );
    subRec[LDR_LIST_BIN] = valueList;
    ldt_common.updateSubRec( src, subRec );
    return 0;
  end -- end of List Mode, start of Sub-Rec Mode

      
  -- Ok -- so we have sub-records.  Version 1 -- let's search the subRec
  -- and if not found, insert.  This is all very similar to the above
  -- list code, except that it's the list from the subRec.
  local digestList = cellAnchor[X_DigestList];
  -- SPECIAL CASE :: ONLY ONE DIGEST IN THE LIST.
  local digestString = tostring( digestList[1] );
  subRec  = ldt_common.openSubRec( src, toprec, digestString );
  valueList = subRec[LDR_LIST_BIN];
  if( valueList == nil ) then
    warn("[INTERNAL ERROR]<%s:%s> Cell Anchor ValueList NIL", MOD, meth );
    error( ldte.ERR_INTERNAL );
  end

  position = searchList( ldtMap, valueList, key );
  if( position > 0 ) then
    warn("[UNIQUE ERROR]<%s:%s> Position(%d) searchKey(%s)",
      MOD, meth, position, tostring(key));
    error( ldte.ERR_UNIQUE_KEY );
  end

  -- Not found.  So, append the item and reassign the list to the subRec.
  list.append( valueList, newValue );
  subRec[LDR_LIST_BIN] = valueList;
  ldt_common.updateSubRec( src, subRec ); -- Mark this dirty.
  if( rc == nil or rc == 0 ) then
    rc = 0;
  else
    error( ldte.ERR_CREATE );
  end -- else sub-record case

  GP=E and trace("[EXIT]<%s:%s>Insert Results: RC(%d) Value(%s) binList(%s)",
    MOD, meth, rc, tostring( newValue ), tostring(binList));

  return rc;
end -- cellAnchorInsert()


-- ======================================================================
-- localSubRecInsert()
-- ======================================================================
-- Perform the main work of insert (used by both rehash and insert).  We
-- locate the "cellAnchor" in the HashDirectory, then either create or insert
-- into the appropriate subrec.
-- Parms:
-- (*) topRec: The top DB Record:
-- (*) ldtCtrl: The LSet control map
-- (*) newValue: Value to be inserted
-- (*) stats: 1=Please update Counts, 0=Do NOT update counts (rehash)
-- RETURN:
--  0: ok
-- -1: Unique Value violation
-- ======================================================================
local function localSubRecInsert( src, topRec, ldtCtrl, newValue, stats )
  local meth = "localSubRecInsert()";
  
  GP=E and trace("[ENTER]:<%s:%s>Insert(%s) stats(%s)",
    MOD, meth, tostring(newValue), tostring(stats));

  local propMap = ldtCtrl[1];  
  local ldtMap = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];
  local rc = 0;
  local key = getKeyValue( ldtMap, newValue );

  -- If we're in compact mode, then just insert there.  The caller will
  -- have already checked for COUNT > REHASH THRESHOLD, so if we're in
  -- compact state we just deal with that directly.
  -- check to see if it's time to rehash.
  if( ldtMap[M_StoreState] == SS_COMPACT ) then
    warn("[INTERNAL STATE ERR]<%s:%s> Compact state in SubRecInsert",MOD,meth);
    local compactList = ldtMap[M_CompactList];
    if( compactList == nil ) then -- Not a likely case, but who knows?
      compactList = list();
      list.append( compactList, newValue );
      ldtMap[M_CompactList] = compactList;
    else
      local position = searchList( ldtMap, compactList, key );
      if( position > 0 ) then
        warn("[UNIQUE ERROR]<%s:%s> key(%s) value(%s) found in list(%s)",
        MOD, meth, tostring(key), tostring(newValue), tostring(compactList));
        error( ldte.ERR_UNIQUE_KEY );
      end
      list.append( compactList, newValue );
    end
  else
    -- Regular SubRec Insert.
    -- We'll get the key and use that to feed to the hash function, which will
    -- tell us what bin we're in.
    local binCell = computeSetBin( key, ldtMap );
    local hashDirectory = ldtMap[M_HashDirectory];
    local cellAnchor = hashDirectory[binCell];
    -- The cellAnchor is either "EMPTY" or it has a valid Cell Anchor structure.
    -- First, check type (string) and value (HC_EMPTY) to see if nothing is
    -- here.  Notice that this means that we have to init the hashDir correctly
    -- when we create it.
    if( cellAnchor ~= nil and type(cellAnchor) == "string" and
        cellAnchor == HV_EMPTY )
    then
      -- Create a new cell Anchor with the new value and store it in HashDir.
      hashDirectory[binCell] = newCellAnchor( newValue ); 
    else
      -- Else we have a real Cell Anchor, so insert there.
      cellAnchorInsert( src, topRec, ldtCtrl, key, newValue );
    end
  end

  -- Update stats if appropriate.
  if( stats == 1 ) then -- Update Stats if success
    local itemCount = propMap[PM_ItemCount];
    local totalCount = ldtMap[M_TotalCount];
    
    propMap[PM_ItemCount] = itemCount + 1; -- number of valid items goes up
    ldtMap[M_TotalCount] = totalCount + 1; -- Total number of items goes up
    topRec[ldtBinName] = ldtCtrl;
    record.set_flags(topRec,ldtBinName,BF_LDT_BIN);--Must set every time

    GP=F and trace("[STATUS]<%s:%s>Updating Stats TC(%d) IC(%d)", MOD, meth,
      ldtMap[M_TotalCount], propMap[PM_ItemCount] );
  else
    GP=F and trace("[STATUS]<%s:%s>NOT updating stats(%d)",MOD,meth,stats);
  end

  GP=E and trace("[EXIT]<%s:%s>Insert Results: RC(%d) Value(%s) binList(%s)",
    MOD, meth, rc, tostring( newValue ), tostring(binList));

  return rc;
end -- localSubRecInsert

-- ======================================================================
-- subRecRehashSet()
-- ======================================================================
-- When we start in "compact" StoreState (SS_COMPACT), we eventually have
-- to switch to "regular" state when we get enough values.  So, at some
-- point (StoreThreshold), we rehash all of the values in the single
-- bin and properly store them in their final resting bins.
-- So -- copy out all of the items from the compact list, null out the
-- compact list and then reinsert them into the regular hash directory.
-- Parms:
-- (*) src
-- (*) topRec
-- (*) ldtCtrl
-- ======================================================================
local function subRecRehashSet( src, topRec, ldtCtrl )
  local meth = "subRecRehashSet()";
  GP=E and trace("[ENTER]:<%s:%s> !!!! SUBREC REHASH !!!! ", MOD, meth );
  GP=E and trace("[ENTER]:<%s:%s> !!!! SUBREC REHASH !!!! ", MOD, meth );

  local propMap = ldtCtrl[1];  
  local ldtMap = ldtCtrl[2];

  local compactList = ldtMap[M_CompactList];
  if compactList == nil then
    warn("[INTERNAL ERROR]:<%s:%s> Rehash can't use Empty list", MOD, meth );
    error( ldte.ERR_INSERT );
  end

  ldtMap[M_StoreState] = SS_REGULAR; -- now in "regular" (modulo) mode
  -- Get a copy of the compact List.  If this doesn't work as expected, then
  -- we will have to get a real "list.take()" copy.
  local listCopy = ldtMap[M_CompactList];
  ldtMap[M_CompactList] = nil; -- zero out before we insert in regular mode
  
  -- Rebuild. Insert into the hash diretory.
  local hashDirectory = list();

  -- Create the subrecs as needed.  But, allocate a hash cell anchor structure
  -- for each directory entry.
  --
  -- Our "indexing" starts with ONE (Lua Array convention) so we must adjust
  -- to a "zero base" when we want to do modulo arithmetic.
  local distrib = ldtMap[M_Modulo];
  for i = 1, distrib , 1 do
    -- assign a new list to topRec[binName]
    hashDirectory[i] = HV_EMPTY;
  end -- for each new hash cell
  ldtMap[M_HashDirectory] = hashDirectory;

  for i = 1, list.size(listCopy), 1 do
    localSubRecInsert(src, topRec, ldtCtrl, listCopy[i], 0); -- no count update
  end

  GP=E and trace("[EXIT]: <%s:%s>", MOD, meth );
end -- subRecRehashSet()

-- ======================================================================
-- validateBinName(): Validate that the user's bin name for this large
-- object complies with the rules of Aerospike. Currently, a bin name
-- cannot be larger than 14 characters (a seemingly low limit).
-- ======================================================================
local function validateBinName( binName )
  local meth = "validateBinName()";
  GP=E and trace("[ENTER]: <%s:%s> validate Bin Name(%s)",
  MOD, meth, tostring(binName));

  if binName == nil  then
    warn("[ERROR EXIT]:<%s:%s> Null Bin Name", MOD, meth );
    error( ldte.ERR_NULL_BIN_NAME );
  elseif type( binName ) ~= "string"  then
    warn("[ERROR EXIT]:<%s:%s> Bin Name Not a String", MOD, meth );
    error( ldte.ERR_BIN_NAME_NOT_STRING );
  elseif string.len( binName ) > 14 then
    warn("[ERROR EXIT]:<%s:%s> Bin Name Too Long", MOD, meth );
    error( ldte.ERR_BIN_NAME_TOO_LONG );
  end
  GP=E and trace("[EXIT]:<%s:%s> Ok", MOD, meth );
end -- validateBinName

-- ======================================================================
-- validateRecBinAndMap():
-- Check that the topRec, the ldtBinName and ldtMap are valid, otherwise
-- jump out with an error() call.
--
-- Parms:
-- (*) topRec:
-- (*) ldtBinName: User's Name for the LDT Bin
-- (*) mustExist: When true, ldtCtrl must exist, otherwise error
-- Return:
--   ldtCtrl -- if "mustExist" is true, otherwise unknown.
-- ======================================================================
local function validateRecBinAndMap( topRec, ldtBinName, mustExist )
  local meth = "validateRecBinAndMap()";
  GP=E and trace("[ENTER]:<%s:%s> BinName(%s) ME(%s)",
        MOD, meth, tostring( ldtBinName ), tostring( mustExist ));


  -- Start off with validating the bin name -- because we might as well
  -- flag that error first if the user has given us a bad name.
  validateBinName( ldtBinName );

  local ldtCtrl;
  local propMap;
  local ldtMap;
  local rc = 0;

  -- If "mustExist" is true, then several things must be true or we will
  -- throw an error.
  -- (*) Must have a record.
  -- (*) Must have a valid Bin
  -- (*) Must have a valid Map in the bin.
  --
  -- If "mustExist" is false, then basically we're just going to check
  -- that our bin includes MAGIC, if it is non-nil.
  if mustExist == true then
    -- Check Top Record Existence.
    if( not aerospike:exists( topRec ) and mustExist == true ) then
      warn("[ERROR EXIT]:<%s:%s>:Missing Record. Exit", MOD, meth );
      error( ldte.ERR_TOP_REC_NOT_FOUND );
    end
      
    -- Control Bin Must Exist, in this case, ldtCtrl is what we check
    if( topRec[ldtBinName] == nil ) then
      warn("[ERROR EXIT]: <%s:%s> LSET_BIN (%s) DOES NOT Exists",
            MOD, meth, tostring(ldtBinName) );
      error( ldte.ERR_BIN_DOES_NOT_EXIST );
    end

    -- check that our bin is (mostly) there
    ldtCtrl = topRec[ldtBinName]; -- The main lset map
    propMap = ldtCtrl[1];
    ldtMap  = ldtCtrl[2];
    
    if(propMap[PM_Magic] ~= MAGIC) or propMap[PM_LdtType] ~= LDT_TYPE_LSET then
      GP=E and warn("[ERROR EXIT]:<%s:%s>LSET_BIN(%s) Corrupted:No magic:1",
            MOD, meth, ldtBinName );
      error( ldte.ERR_BIN_DAMAGED );
    end
    -- Ok -- all done for the Must Exist case.
  else
    -- OTHERWISE, we're just checking that nothing looks bad, but nothing
    -- is REQUIRED to be there.  Basically, if a control bin DOES exist
    -- then it MUST have magic.
    if topRec ~= nil and topRec[ldtBinName] ~= nil then
       ldtCtrl = topRec[ldtBinName]; -- The main lset map
       propMap = ldtCtrl[1];
       ldtMap  = ldtCtrl[2];
    
       if( propMap[PM_Magic] ~= MAGIC ) or propMap[PM_LdtType] ~= LDT_TYPE_LSET
         then
        GP=E and warn("[ERROR EXIT]:<%s:%s>LSET_BIN<%s:%s>Corrupted:No magic:2",
              MOD, meth, ldtBinName, tostring( ldtMap ));
        error( ldte.ERR_BIN_DAMAGED );
      end
    end -- if worth checking
  end -- else for must exist

  -- Finally -- let's check the version of our code against the version
  -- in the data.  If there's a mismatch, then kick out with an error.
  -- Although, we check this ONLY in the "must exist" case.
  if( mustExist == true ) then
    local dataVersion = 0;
    if( propMap[PM_Version] ~= nil and type(propMap[PM_Version] == "number") )
    then
      dataVersion = propMap[PM_Version];
    end
  
    if( G_LDT_VERSION > dataVersion ) then
      GP=E and warn("[ERROR EXIT]<%s:%s> Code Version (%d) <> Data Version(%d)",
        MOD, meth, G_LDT_VERSION, dataVersion );
      error( ldte.ERR_VERSION_MISMATCH );
    end
  end -- final version check
  
  GP=E and trace("[EXIT]<%s:%s> rc(%s)", MOD, meth, tostring(rc) );
  return ldtCtrl; -- Save the caller the effort of extracting the map.
end -- validateRecBinAndMap()

-- ======================================================================
-- processModule()
-- ======================================================================
-- We expect to see several things from a user module.
-- (*) An adjust_settings() function: where a user overrides default settings
-- (*) Various filter functions (callable later during search)
-- (*) Transformation functions
-- (*) UnTransformation functions
-- The settings and transformation/untransformation are all set from the
-- adjust_settings() function, which puts these values in the control map.
-- ======================================================================
local function processModule( ldtCtrl, moduleName )
  local meth = "processModule()";
  GP=E and trace("[ENTER]<%s:%s> Process User Module(%s)", MOD, meth,
    tostring( moduleName ));

  local propMap = ldtCtrl[1];
  local ldtMap = ldtCtrl[2];

  if( moduleName ~= nil ) then
    if( type(moduleName) ~= "string" ) then
      warn("[ERROR]<%s:%s>User Module(%s) not valid::wrong type(%s)",
        MOD, meth, tostring(moduleName), type(moduleName));
      error( ldte.ERR_USER_MODULE_BAD );
    end

    local userModule = require(moduleName);
    if( userModule == nil ) then
      warn("[ERROR]<%s:%s>User Module(%s) not valid", MOD, meth, moduleName);
      error( ldte.ERR_USER_MODULE_NOT_FOUND );
    else
      local userSettings =  userModule[G_SETTINGS];
      if( userSettings ~= nil ) then
        userSettings( ldtMap ); -- hope for the best.
        ldtMap[M_UserModule] = moduleName;
      end
    end
  else
    warn("[ERROR]<%s:%s>User Module is NIL", MOD, meth );
  end

  GP=E and trace("[EXIT]<%s:%s> Module(%s) LDT CTRL(%s)", MOD, meth,
    tostring( moduleName ), ldtSummaryString(ldtCtrl));

end -- processModule()

-- ======================================================================
-- setupLdtBin()
-- ======================================================================
-- Caller has already verified that there is no bin with this name,
-- so we're free to allocate and assign a newly created LDT CTRL
-- in this bin.
-- ALSO:: Caller write out the LDT bin after this function returns.
-- Return:
--   The newly created ldtCtrl Map
-- ======================================================================
local function setupLdtBin( topRec, ldtBinName, userModule ) 
  local meth = "setupLdtBin()";
  GP=E and trace("[ENTER]<%s:%s> binName(%s)",MOD,meth,tostring(ldtBinName));

  local ldtCtrl = initializeLdtCtrl( topRec, ldtBinName );
  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2]; 
  
  -- Set the type of this record to LDT (it might already be set)
  -- No Longer needed.  The Set Type is handled in initializeLdtCtrl()
  -- record.set_type( topRec, RT_LDT ); -- LDT Type Rec
  
  -- If the user has passed in settings that override the defaults
  -- (the userModule), then process that now.
  if( userModule ~= nil )then
    local createSpecType = type(userModule);
    if( createSpecType == "string" ) then
      processModule( ldtCtrl, userModule );
    elseif( createSpecType == "userdata" ) then
      adjustLdtMap( ldtMap, userModule );
    else
      warn("[WARNING]<%s:%s> Unknown Creation Object(%s)",
        MOD, meth, tostring( userModule ));
    end
  end

  GP=F and trace("[DEBUG]: <%s:%s> : CTRL Map after Adjust(%s)",
                 MOD, meth , tostring(ldtMap));

  -- Sets the topRec control bin attribute to point to the two item list
  -- we created from InitializeLSetMap() : 
  -- Item 1 : the property map 
  -- Item 2 : the ldtMap
  topRec[ldtBinName] = ldtCtrl; -- store in the record
  record.set_flags( topRec, ldtBinName, BF_LDT_BIN );

  -- initializeLdtCtrl always sets ldtMap[M_StoreState] to SS_COMPACT.
  -- When in TopRec mode, there is only one bin.
  -- When in SubRec mode, there's only one hash cell.
  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Setup the compact list in sub-rec mode.  This will eventually 
    -- rehash into a full size hash directory.
    ldtMap[M_CompactList] = list();
  else
    -- Setup the compact list in topRec mode
    -- This one will assign the actual record-list to topRec[binName]
    setupNewBin( topRec, 0 );
  end

  -- NOTE: The Caller will write out the LDT bin.
  return ldtCtrl;
end -- setupLdtBin()

-- ======================================================================
-- topRecInsert()
-- ======================================================================
-- Insert a value into the set.
-- Take the value, perform a hash and a modulo function to determine which
-- bin list is used, then add to the list.
--
-- We will use predetermined BIN names for this initial prototype
-- 'LSetCtrlBin' will be the name of the bin containing the control info
-- 'LSetBin_XX' will be the individual bins that hold lists of data
-- Notice that this means that THERE CAN BE ONLY ONE AS Set object per record.
-- In the final version, this will change -- there will be multiple 
-- AS Set bins per record.  We will switch to a modified bin naming scheme.
--
-- NOTE: Design, V2.  We will cache all data in the FIRST BIN until we
-- reach a certain number N (e.g. 100), and then at N+1 we will create
-- all of the remaining bins in the record and redistribute the numbers, 
-- then insert the 101th value.  That way we save the initial storage
-- cost of small, inactive or dead users.
-- ==> The CtrlMap will show which state we are in:
-- (*) StoreState=SS_COMPACT: We are in SINGLE BIN state (no hash)
-- (*) StoreState=SS_REGULAR: We hash, mod N, then insert (append) into THAT bin.
--
-- +========================================================================+=~
-- | Usr Bin 1 | Usr Bin 2 | o o o | Usr Bin N | Set CTRL BIN | Set Bins... | ~
-- +========================================================================+=~
--    ~=+===========================================+
--    ~ | Set Bin 1 | Set Bin 2 | o o o | Set Bin N |
--    ~=+===========================================+
--            V           V                   V
--        +=======+   +=======+           +=======+
--        |V List |   |V List |           |V List |
--        +=======+   +=======+           +=======+
--
-- Parms:
-- (*) topRec: the Server record that holds the Large Set Instance
-- (*) ldtCtrl: The name of the bin for the AS Large Set
-- (*) newValue: Value to be inserted into the Large Set
-- ======================================================================
local function topRecInsert( topRec, ldtCtrl, newValue )
  local meth = "topRecInsert()";
  
  GP=E and trace("[ENTER]:<%s:%s> LDT CTRL(%s) NewValue(%s)",
                 MOD, meth, tostring(ldtCtrl), tostring( newValue ) );

  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- When we're in "Compact" mode, before each insert, look to see if 
  -- it's time to rehash our single bin into all bins.
  local totalCount = ldtMap[M_TotalCount];
  local itemCount = propMap[PM_ItemCount];
  
  GP=F and trace("[DEBUG]<%s:%s>Store State(%s) Total Count(%d) ItemCount(%d)",
    MOD, meth, tostring(ldtMap[M_StoreState]), totalCount, itemCount );

  if ldtMap[M_StoreState] == SS_COMPACT and
    totalCount >= ldtMap[M_ThreshHold]
  then
    GP=F and trace("[DEBUG]<%s:%s> CALLING REHASH BEFORE INSERT", MOD, meth);
    topRecRehashSet( topRec, ldtCtrl );
  end

  -- Call our local multi-purpose insert() to do the job.(Update Stats)
  -- localTopRecInsert() will jump out with its own error call if something bad
  -- happens so no return code (or checking) needed here.
  localTopRecInsert( topRec, ldtCtrl, newValue, 1 );

  -- NOTE: the update of the TOP RECORD has already
  -- been taken care of in localTopRecInsert, so we don't need to do it here.
  --
  -- All done, store the record
  GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", MOD, meth );
  local rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=E and trace("[EXIT]: <%s:%s> : Done.  RC(%d)", MOD, meth, rc );
  return rc;
end -- function topRecInsert()

-- ======================================================================
-- subRecInsert()
-- ======================================================================
-- Insert a value into the set, using the SubRec design.
-- Take the value, perform a hash and a modulo function to determine which
-- directory cell is used, open the appropriate subRec, then add to the list.
--
-- Parms:
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- (*) topRec: the Server record that holds the Large Set Instance
-- (*) ldtCtrl: The name of the bin for the AS Large Set
-- (*) newValue: Value to be inserted into the Large Set
-- ======================================================================
local function subRecInsert( src, topRec, ldtCtrl, newValue )
  local meth = "subRecInsert()";
  
  GP=E and trace("[ENTER]:<%s:%s> LDT CTRL(%s) NewValue(%s)",
                 MOD, meth, ldtSummaryString(ldtCtrl), tostring( newValue ));

  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- When we're in "Compact" mode, before each insert, look to see if 
  -- it's time to rehash the compact list into the full directory structure.
  local totalCount = ldtMap[M_TotalCount];
  local itemCount = propMap[PM_ItemCount];
  
  GP=F and trace("[DEBUG]<%s:%s>Store State(%s) Total Count(%d) ItemCount(%d)",
    MOD, meth, tostring(ldtMap[M_StoreState]), totalCount, itemCount );

  if ldtMap[M_StoreState] == SS_COMPACT and
    totalCount >= ldtMap[M_ThreshHold]
  then
    GP=F and trace("[DEBUG]<%s:%s> CALLING REHASH BEFORE INSERT", MOD, meth);
    subRecRehashSet( src, topRec, ldtCtrl );
  end

  -- Call our local multi-purpose insert() to do the job.(Update Stats)
  -- localSubRecInsert() will jump out with its own error call if something bad
  -- happens so no return code (or checking) needed here.
  localSubRecInsert( src, topRec, ldtCtrl, newValue, 1 );

  -- NOTE: the update of the TOP RECORD has already
  -- been taken care of in localSubRecInsert, so we don't need to do it here.
  --
  -- Store it again here -- for now.  Remove later, when we're sure.  
  topRec[ldtBinName] = ldtCtrl;
  -- Also -- in Lua -- all data (like the maps and lists) are inked by
  -- reference -- so they do not need to be "re-updated".  However, the
  -- record itself, must have the object re-assigned to the BIN.
  -- Also -- must ALWAYS reset the bin flag, every time.
  record.set_flags(topRec, ldtBinName, BF_LDT_BIN );--Must set every time
  
  -- All done, store the record
  GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", MOD, meth );
  local rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=E and trace("[EXIT]: <%s:%s> : Done.  RC(%d)", MOD, meth, rc );
  return 0;
end -- function subRecInsert()

-- ======================================================================
-- ======================================================================
-- old code
  -- We can't simply NULL out the entry -- because that breaks the bin
  -- when we try to store.  So -- we'll instead replace this current entry
  -- with the END entry -- and then we'll COPY (take) the list ... until
  -- we have the ability to truncate a list in place.
  -- local listSize = list.size( binList );
  -- if( position < listSize ) then
    -- binList[position] = binList[listSize];
  -- end
  -- local newBinList = list.take( binList, listSize - 1 );
-- ======================================================================
--
-- ======================================================================
-- listDelete()
-- ======================================================================
-- General List Delete function that can be used to delete items.
-- RETURN:
-- A NEW LIST that no longer includes the deleted item.
-- ======================================================================
local function listDelete( objectList, position )
  local meth = "listDelete()";
  local resultList;
  local listSize = list.size( objectList );

  GP=E and trace("[ENTER]<%s:%s>List(%s) size(%d) Position(%d)", MOD,
  meth, tostring(objectList), listSize, position );
  
  if( position < 1 or position > listSize ) then
    warn("[DELETE ERROR]<%s:%s> Bad position(%d) for delete.",
      MOD, meth, position );
    error( ldte.ERR_DELETE );
  end

  -- Move elements in the list to "cover" the item at Position.
  --  +---+---+---+---+
  --  |111|222|333|444|   Delete item (333) at position 3.
  --  +---+---+---+---+
  --  Moving forward, Iterate:  list[pos] = list[pos+1]
  --  This is what you would THINK would work:
  -- for i = position, (listSize - 1), 1 do
  --   objectList[i] = objectList[i+1];
  -- end -- for()
  -- objectList[i+1] = nil;  (or, call trim() )
  -- However, because we cannot assign "nil" to a list, nor can we just
  -- trim a list, we have to build a NEW list from the old list, that
  -- contains JUST the pieces we want.
  -- So, basically, we're going to build a new list out of the LEFT and
  -- RIGHT pieces of the original list.
  --
  -- Our List operators :
  -- (*) list.take (take the first N elements) 
  -- (*) list.drop (drop the first N elements, and keep the rest) 
  -- The special cases are:
  -- (*) A list of size 1:  Just return a new (empty) list.
  -- (*) We're deleting the FIRST element, so just use RIGHT LIST.
  -- (*) We're deleting the LAST element, so just use LEFT LIST
  if( listSize == 1 ) then
    resultList = list();
  elseif( position == 1 ) then
    resultList = list.drop( objectList, 1 );
  elseif( position == listSize ) then
    resultList = list.take( objectList, position - 1 );
  else
    resultList = list.take( objectList, position - 1);
    local addList = list.drop( objectList, position );
    local addLength = list.size( addList );
    for i = 1, addLength, 1 do
      list.append( resultList, addList[i] );
    end
  end

  GP=F and trace("[EXIT]<%s:%s>List(%s)", MOD, meth, tostring(resultList));
  return resultList;
end -- listDelete()

-- ======================================================================
-- subRecDelete()
-- ======================================================================
-- Sub Record Mode: 
-- Find an element (i.e. search) and then remove it from the list.
-- Return the element if found, return nil if not found.
-- Parms:
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- (*) topRec:
-- (*) ldtCtrl
-- (*) deleteValue:
-- (*) returnVal;  when true, return the deleted value.
-- ======================================================================
local function subRecDelete(src, topRec, ldtCtrl, deleteValue, returnVal)
  local meth = "subRecDelete()";
  GP=E and trace("[ENTER]: <%s:%s> Delete Value(%s)",
                 MOD, meth, tostring( deleteValue ) );

  local rc = 0; -- start out OK.
  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2]; 

  -- Compute the subRec address that holds the deleteValue
  local cellNumber = computeHashCell( deleteValue, ldtMap );
  local hashDirectory = ldtMap[M_HashDirectory];
  local cellAnchor = hashDirectory[cellNumber];
  local subRec;
  local valueList;

  -- If no sub-record, then not found.
  if( cellAnchor == nil or
      cellAnchor == 0 or
      cellAnchor[C_CellState] == nil or
      cellAnchor[C_CellState] == C_STATE_EMPTY )
  then
    warn("[NOT FOUND]<%s:%s> deleteValue(%s)", MOD, meth, tostring(deleteValue));
    error( ldte.ERR_NOT_FOUND );
  end

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- If not empty, then the cell anchor must be either in an empty
  -- state, or it has a Sub-Record.  Later, it might have a Radix tree
  -- of multiple Sub-Records.
  if( cellAnchor[C_CellState] == C_STATE_LIST ) then
    -- The small list is inside of the cell anchor.  Get the lists.
    valueList = cellAnchor[C_CellValueList];
  elseif( cellAnchor[C_CellState] == C_STATE_DIGEST ) then
    -- If the cell state is NOT empty and NOT a list, it must be a subrec.
    -- We have a sub-rec -- open it
    local digest = cellAnchor[C_CellDigest];
    if( digest == nil ) then
      warn("[ERROR]: <%s:%s>: nil Digest value",  MOD, meth );
      error( ldte.ERR_SUBREC_OPEN );
    end

    local digestString = tostring(digest);
    -- NOTE: openSubRec() does its own error checking. No more needed here.
    local subRec = ldt_common.openSubRec( src, topRec, digestString );

    valueList = subRec[LDR_LIST_BIN];
    if( valueList == nil ) then
      warn("[ERROR]<%s:%s> Empty Value List: ", MOD, meth );
      error( ldte.ERR_INTERNAL );
    end
  else
    -- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    -- When we do a Radix Tree, we will STILL end up with a SubRecord
    -- but it will come from a Tree.  We just need to manage the SubRec
    -- correctly.
    warn("[ERROR]<%s:%s> Not yet ready to handle Radix Trees in Hash Cell",
      MOD, meth );
    error( ldte.ERR_INTERNAL );
    -- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  end

  local position = searchList( ldtCtrl, valueList, deleteValue );
  if( position == 0 ) then
    -- Didn't find it -- report an error.  But First -- Close the subRec.
    ldt_common.closeSubRec( src, subRec, false);

    warn("[NOT FOUND]<%s:%s> deleteVal(%s)", MOD, meth, tostring(deleteValue));
    error( ldte.ERR_NOT_FOUND );
  end

  -- ok -- found it, so let's delete the value. Notice that we don't
  -- need to UNTRANSFORM or check a filter here.  Just remove.
  --
  -- listDelete() will generate a new list, so we store that back into
  -- where we got the list:
  -- (*) The Cell Anchor List
  -- (*) The Sub-Record.
  resultMap[searchName] = validateValue( valueList[position] );
  if( cellAnchor[C_CellState] == C_STATE_LIST ) then
    cellAnchor[C_CellValueList] = valueList;
  else
    subRec[LDR_LIST_BIN] = listDelete( valueList, position );
  end

  GP=E and trace("[EXIT]<%s:%s> FOUND: Pos(%d)", MOD, meth, position );
  return 0;
end -- function subRecDelete()

-- ======================================================================
-- topRecDelete()
-- ======================================================================
-- Top Record Mode
-- Find an element (i.e. search) and then remove it from the list.
-- Return the element if found, return nil if not found.
-- Parms:
-- (*) topRec:
-- (*) ldtCtrl
-- (*) deleteValue:
-- (*) returnVal;  when true, return the deleted value.
-- ======================================================================
local function topRecDelete( topRec, ldtCtrl, deleteValue, returnVal)
  local meth = "topRecDelete()";
  GP=E and trace("[ENTER]: <%s:%s> Delete Value(%s)",
                 MOD, meth, tostring( deleteValue ) );

  local rc = 0; -- Start out ok.
  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];

  -- Get the value we'll compare against
  local key = getKeyValue( ldtMap, deleteValue );

  -- Find the appropriate bin for the Search value
  local binNumber = computeSetBin( key, ldtMap );
  local binName = getBinName( binNumber );
  local binList = topRec[binName];
  local liveObject = nil;
  local resultFitlered = nil;
  local position = 0;

  -- We bother to search only if there's a real list.
  if binList ~= nil and list.size( binList ) > 0 then
    position = searchList( ldtMap, binList, key );
    if( position > 0 ) then
      -- Apply the filter to see if this item qualifies
      -- First -- we have to untransform it (sadly, again)
      local item = binList[position];
      if G_UnTransform ~= nil then
        liveObject = G_UnTransform( item );
      else
        liveObject = item;
      end

      -- APPLY FILTER HERE, if we have one.
      if G_Filter ~= nil then
        resultFiltered = G_Filter( liveObject, G_FunctionArgs );
      else
        resultFiltered = liveObject;
      end
    end -- if search found something (pos > 0)
  end -- if there's a list

  if( position == 0 or resultFiltered == nil ) then
    warn("[WARNING]<%s:%s> Value not found: Value(%s) SearchKey(%s)",
      MOD, meth, tostring(deleteValue), tostring(key));
    error( ldte.ERR_NOT_FOUND );
  end

  -- ok, we got the value.  Remove it and update the record.  Also,
  -- update the stats.
  -- OK -- we can't simply NULL out the entry -- because that breaks the bin
  -- when we try to store.  So -- we'll instead replace this current entry
  -- with the END entry -- and then we'll COPY (take) the list ... until
  -- we have the ability to truncate a list in place.
  local listSize = list.size( binList );
  if( position < listSize ) then
    binList[position] = binList[listSize];
  end
  local newBinList = list.take( binList, listSize - 1 );

  -- NOTE: The MAIN record LDT bin, holding ldtCtrl, is of type BF_LDT_BIN,
  -- but the LSET named bins are of type BF_LDT_HIDDEN.
  topRec[binName] = newBinList;
  record.set_flags(topRec, binName, BF_LDT_HIDDEN );--Must set every time

  -- The caller will update the stats and update the main ldt bin.

  GP=E and trace("[EXIT]<%s:%s>: Success: DeleteValue(%s) Res(%s) binList(%s)",
    MOD, meth, tostring( deleteValue ), tostring(resultFiltered),
    tostring(binList));
  if( returnVal == true ) then
    return resultFiltered;
  else
    return 0;
  end
end -- function topRecDelete()

-- ========================================================================
-- subRecDump()
-- ========================================================================
-- Dump the full contents of the Large Set, with Separate Hash Groups
-- shown in the result.
-- Return a LIST of lists -- with Each List marked with it's Hash Name.
-- ========================================================================
local function subRecDump( src, topRec, ldtCtrl )
  local meth = "subRecDump()";
  GP=E and trace("[ENTER]<%s:%s>LDT(%s)", MOD, meth,ldtSummaryString(ldtCtrl));

  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];

  resultMap = map();

  local resultList = list(); -- list of BIN LISTS
  local listCount = 0;
  local transform = nil;
  local unTransform = nil;
  local retValue = nil;

  -- Loop through the Hash Directory, get each cellAnchor, and show the
  -- cellAnchorSummary.
  --
  local tempList;
  local binList;
  local hashDirectory = ldtMap[M_HashDirectory];
  for j = 0, (distrib - 1), 1 do
    local cellAnchor = hashDirectory[j];
    resultMap[j] = cellAnchorDump( src, topRec, cellAnchor );
  end -- for each cell

  GP=E and trace("[EXIT]<%s:%s>ResultList(%s)",MOD,meth,tostring(resultList));
  return resultMap;

end -- subRecDump();

-- ========================================================================
-- topRecDump()
-- ========================================================================
-- Dump the full contents of the Large Set, with Separate Hash Groups
-- shown in the result.
-- Return a LIST of lists -- with Each List marked with it's Hash Name.
-- ========================================================================
local function topRecDump( topRec, ldtCtrl )
  local meth = "TopRecDump()";
  GP=E and trace("[ENTER]<%s:%s>LDT(%s)", MOD, meth,ldtSummaryString(ldtCtrl));

  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];

  local resultList = list(); -- list of BIN LISTS
  local listCount = 0;
  local transform = nil;
  local unTransform = nil;
  local retValue = nil;

  -- Loop through all the modulo n lset-record bins 
  local distrib = ldtMap[M_Modulo];

  GP=F and trace(" Number of LSet bins to parse: %d ", distrib)

  local tempList;
  local binList;
  for j = 0, (distrib - 1), 1 do
	local binName = getBinName( j );
    tempList = topRec[binName];
    binList = list();
    list.append( binList, binName );
    if( tempList == nil or list.size( tempList ) == 0 ) then
      list.append( binList, "EMPTY LIST")
    else
      listAppend( binList, tempList );
    end
    trace("[DEBUG]<%s:%s> BIN(%s) TList(%s) B List(%s)", MOD, meth, binName,
      tostring(tempList), tostring(binList));
    list.append( resultList, binList );
  end -- end for distrib list for-loop 

  GP=E and trace("[EXIT]<%s:%s>ResultList(%s)",MOD,meth,tostring(resultList));

end -- topRecDump();


-- ========================================================================
-- localDump()
-- ========================================================================
-- Dump the full contents of the Large Set, with Separate Hash Groups
-- shown in the result.
-- Return a LIST of lists -- with Each List marked with it's Hash Name.
-- ========================================================================
local function localDump( src, topRec, ldtBinName )
  local meth = "localDump()";
  GP=E and trace("[ENTER]<%s:%s> Bin(%s)", MOD, meth,tostring(ldtBinName));

  local ldtCtrl = topRec[ldtBinName];
  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];

  local resultMap;

  -- Check once for the untransform functions -- so we don't need
  -- to do it inside the loop.  No filters here, though.
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, false, G_KeyFunction );
  G_Filter, G_UnTransform = ldt_common.setReadFunctions( ldtMap, nil, nil );

  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Use the SubRec style Destroy
    resultMap = subRecDump( src, topRec, ldtCtrl );
  else
    -- Use the TopRec style Destroy (this is default if the subrec style
    -- is not specifically requested).
    resultMap = topRecDump( topRec, ldtCtrl );
  end

  return resultMap; 
end -- localDump();

-- ========================================================================
-- topRecDestroy() -- Remove the LDT entirely from the TopRec LSET record.
-- ========================================================================
-- Release all of the storage associated with this LDT and remove the
-- control structure of the bin.  The Parent (caller) has already dealt 
-- with the HIDDEN LDT CONTROL BIN.
--
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtCtrl: The LDT Control Structure.
-- Result:
--   res = 0: all is well
--   res = -1: Some sort of error
-- ========================================================================
local function topRecDestroy( topRec, ldtCtrl )
  local meth = "topRecDestroy()";

  GP=E and trace("[ENTER]: <%s:%s> LDT CTRL(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl));
  local rc = 0; -- start off optimistic

  -- The caller has already dealt with the Common/Hidden LDT Prop Bin.
  -- All we need to do here is deal with the Numbered bins.
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local ldtBinName = propMap[PM_BinName];

  -- Address the TopRecord version here.
  -- Loop through all the modulo n lset-record bins 
  -- Go thru and remove (mark nil) all of the LSET LIST bins.
  local distrib = ldtMap[M_Modulo];
  for j = 0, (distrib - 1), 1 do
	local binName = getBinName( j );
    -- Remove this bin -- assuming it is not already nil.  Setting a 
    -- non-existent bin to nil seems to piss off the lower layers. 
    if( topRec[binName] ~= nil ) then
        topRec[binName] = nil;
    end
  end -- end for distrib list for-loop 

  -- Mark the enitre control-info structure nil.
  topRec[ldtBinName] = nil;

end -- topRecDestroy()


-- ========================================================================
-- subRecDestroy() -- Remove the LDT (and subrecs) entirely from the record.
-- Remove the ESR, Null out the topRec bin.
-- ========================================================================
-- Release all of the storage associated with this LDT and remove the
-- control structure of the bin.  The Parent (caller) has already dealt 
-- with the HIDDEN LDT CONTROL BIN.
--
-- Parms:
-- (1) src: Sub-Rec Context - Needed for repeated calls from caller
-- (2) topRec: the user-level record holding the LDT Bin
-- (3) ldtCtrl: The LDT Control Structure.
-- Result:
--   res = 0: all is well
--   res = -1: Some sort of error
-- ========================================================================
local function subRecDestroy( src, topRec, ldtCtrl )
  local meth = "subRecDestroy()";

  GP=E and trace("[ENTER]: <%s:%s> LDT CTRL(%s)",
    MOD, meth, ldtSummaryString(ldtCtrl));
  local rc = 0; -- start off optimistic

  -- Extract the property map and lso control map from the LDT Control
  local propMap = ldtCtrl[1];
  local ldtMap = ldtCtrl[2];
  local binName = propMap[PM_BinName];

  GP=F and trace("[STATUS]<%s:%s> propMap(%s) LDT Summary(%s)", MOD, meth,
    tostring( propMap ), ldtSummaryString( ldtCtrl ));

  -- Get the ESR and delete it -- if it exists.  If we have ONLY an initial
  -- compact list, then the ESR will be ZERO.
  local esrDigest = propMap[PM_EsrDigest];
  if( esrDigest ~= nil and esrDigest ~= 0 ) then
    local esrDigestString = tostring(esrDigest);
    info("[SUBREC OPEN]<%s:%s> Digest(%s)", MOD, meth, esrDigestString );
    local esrRec = ldt_common.openSubRec( src, topRec, esrDigestString );
    if( esrRec ~= nil ) then
      rc = ldt_common.removeSubRec( src, esrDigestString );
      if( rc == nil or rc == 0 ) then
        GP=F and trace("[STATUS]<%s:%s> Successful CREC REMOVE", MOD, meth );
      else
        warn("[ESR DELETE ERROR]<%s:%s>RC(%d) Bin(%s)", MOD, meth, rc, binName);
        error( ldte.ERR_SUBREC_DELETE );
      end
    else
      warn("[ESR DELETE ERROR]<%s:%s> ERROR on ESR Open", MOD, meth );
    end
  else
    info("[INFO]<%s:%s> LDT ESR is not yet set, so remove not needed. Bin(%s)",
    MOD, meth, binName );
  end

  topRec[binName] = nil;

end -- subRecDestroy()

-- ======================================================================
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Large Set (LSET) Library Functions
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- NOTE: Requirements/Restrictions (this version).
-- (1) One Set Per Record if using "TopRecord" Mode
-- ======================================================================
-- (*) Status = add( topRec, ldtBinName, newValue, userModule, src)
-- (*) Status = add_all( topRec, ldtBinName, valueList, userModule, src)
-- (*) Object = get( topRec, ldtBinName, searchValue, src) 
-- (*) Number  = exists( topRec, ldtBinName, searchValue, src) 
-- (*) List   = scan( topRec, ldtBinName, userModule, filter, fargs, src)
-- (*) Status = remove( topRec, ldtBinName, searchValue, src) 
-- (*) Status = destroy( topRec, ldtBinName, src)
-- (*) Number = size( topRec, ldtBinName )
-- (*) Map    = get_config( topRec, ldtBinName )
-- (*) Status = set_capacity( topRec, ldtBinName, new_capacity)
-- (*) Status = get_capacity( topRec, ldtBinName )
-- ======================================================================
-- The following functions are deprecated:
-- (*) Status = create( topRec, ldtBinName, userModule )
-- ======================================================================
-- We define a table of functions that are visible to both INTERNAL UDF
-- calls and to the EXTERNAL LDT functions.  We define this table, "lset",
-- which contains the functions that will be visible to the module.
local lset = {};
-- ======================================================================

-- ======================================================================
-- lset.create() -- Create an LSET Object in the record bin.
-- ======================================================================
-- There are two different implementations of LSET.  One stores ALL data
-- in the top record, and the other uses the traditional LDT sub-record
-- style.  A configuration setting determines which style is used.
-- Please see the file: doc_lset.md (Held in the  same directory as this
-- lua file) for additional information on the two types of LSET.
--
-- Parms:
-- (*) topRec: The Aerospike Server record on which we operate
-- (*) ldtBinName: The name of the bin for the AS Large Set
-- (*) userModule: A map of create specifications:  Most likely including
--               :: a package name with a set of config parameters.
-- Result:
--   rc = 0: Ok, LDT created
--   rc < 0: Error.
-- ======================================================================
function lset.create( topRec, ldtBinName, userModule )
  GP=B and trace("\n\n >>>>>>>>> API[ LSET CREATE ] <<<<<<<<<< \n");
  local meth = "lset.create()";
  GP=E and trace("[ENTER]: <%s:%s> Bin(%s) createSpec(%s)",
                 MOD, meth, tostring(ldtBinName), tostring(userModule) );

  -- First, check the validity of the Bin Name.
  -- This will throw and error and jump out of Lua if ldtBinName is bad.
  validateBinName( ldtBinName );
  local rc = 0;

  -- Check to see if LDT Structure (or anything) is already there,
  -- and if so, error.  We don't check for topRec already existing,
  -- because that is NOT an error.  We may be adding an LDT field to an
  -- existing record.
  if( topRec[ldtBinName] ~= nil ) then
    warn("[ERROR EXIT]: <%s:%s> LDT BIN (%s) Already Exists",
                   MOD, meth, ldtBinName );
    error( ldte.ERR_BIN_ALREADY_EXISTS );
  end
  
  GP=F and trace("[DEBUG]: <%s:%s> : Initialize SET CTRL Map", MOD, meth );

  -- We need a new LDT bin -- set it up.
  local ldtCtrl = setupLdtBin( topRec, ldtBinName, userModule );

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", MOD, meth );
  local rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=E and trace("[EXIT]: <%s:%s> : Done.  RC(%d)", MOD, meth, rc );
  return rc;
end -- lset.create()

-- ======================================================================
-- lset.add()
-- ======================================================================
-- Perform the local insert, for whichever mode (toprec, subrec) is
-- called for.
-- Parms:
-- (*) topRec: The Aerospike Server record on which we operate
-- (*) ldtBinName: The name of the bin for the AS Large Set
-- (*) newValue: The new Object to be placed into the set.
-- (*) userModule: A map of create specifications:  Most likely including
--               :: a package name with a set of config parameters.
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- Result:
-- ======================================================================
-- TODO: Add a common core "local insert" that can be used by both this
-- function and the lset.all_all() function.
-- ======================================================================
function lset.add( topRec, ldtBinName, newValue, userModule, src )
  GP=B and trace("\n\n  >>>>>>>>>>>>> API[ add ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "lset.add()";
  
  GP=E and trace("[ENTER]:<%s:%s> LSetBin(%s) NewValue(%s) createSpec(%s)",
                 MOD, meth, tostring(ldtBinName), tostring( newValue ),
                 tostring( userModule ));

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  -- NOTE: Can't get ldtCtrl from this call when "mustExist" is false.
  validateRecBinAndMap( topRec, ldtBinName, false );

  -- If the bin is not already set up, then create.
  if( topRec[ldtBinName] == nil ) then
    GP=F and trace("[INFO]: <%s:%s> LSET BIN (%s) does not Exist:Creating",
         MOD, meth, tostring( ldtBinName ));

    -- We need a new LDT bin -- set it up.
    setupLdtBin( topRec, ldtBinName, userModule );
  end

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  local ldtCtrl = topRec[ldtBinName]; -- The main lset control structure
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];
  local rc = 0;

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- Set up the Read/Write Functions (KeyFunction, Transform, Untransform)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, false, G_KeyFunction );
  G_Filter, G_UnTransform = ldt_common.setReadFunctions( ldtMap, nil, nil );
  G_Transform = ldt_common.setWriteFunctions( ldtMap );

  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Use the SubRec style Insert
    subRecInsert( src, topRec, ldtCtrl, newValue );
  else
    -- Use the TopRec style Insert (this is default if the subrec style
    -- is not specifically requested).
    topRecInsert( topRec, ldtCtrl, newValue );
  end

  -- No need to update the counts here, since the called functions handle
  -- that.  All we need to do is write out the record.
  rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=E and trace("[EXIT]:<%s:%s> RC(0)", MOD, meth );
  return rc;
end -- lset.add()

-- ======================================================================
-- lset.add_all() -- Add a LIST of elements to the set.
-- ======================================================================
-- Iterate thru the value list and insert each item using the regular
-- insert.  We don't expect that the list will be long enough to warrant
-- any special processing.
-- TODO: Switch to using a common "core insert" for lset.add() and 
-- lset.add_all() so that we don't perform the initial checking for EACH
-- element in this list.
-- Parms:
-- (*) topRec: The Aerospike Server record on which we operate
-- (*) ldtBinName: The name of the bin for the AS Large Set
-- (*) valueList: The list of Objects to be placed into the set.
-- (*) userModule: A map of create specifications:  Most likely including
--               :: a package name with a set of config parameters.
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- Result:
-- ======================================================================
function lset.add_all( topRec, ldtBinName, valueList, userModule, src )
  local meth = "lset.add_all()";
  local rc = 0;

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  if( valueList ~= nil and list.size(valueList) > 0 ) then
    local listSize = list.size( valueList );
    for i = 1, listSize, 1 do
      rc = lset.add( topRec, ldtBinName, valueList[i], userModule, src );
      if( rc < 0 ) then
        warn("[ERROR]<%s:%s> Problem Inserting Item #(%d) [%s]", MOD, meth, i,
          tostring( valueList[i] ));
          error(ldte.ERR_INSERT);
      end
    end
  else
    warn("[ERROR]<%s:%s> Invalid Input Value List(%s)",
      MOD, meth, tostring(valueList));
    error(ldte.ERR_INPUT_PARM);
  end
  return rc;
end -- function lset.add_all()

-- ======================================================================
-- lset.get(): Return the object matching <searchValue>
-- ======================================================================
-- Find an element (i.e. search), and optionally apply a filter.
-- Return the element if found, return an error (NOT FOUND) otherwise
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) searchValue:
-- (*) userModule: The Lua File that contains the filter.
-- (*) filter: the NAME of the filter function (which we'll find in FuncTable)
-- (*) fargs: Optional Arguments to feed to the filter
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- Return the object, or Error (NOT FOUND)
-- ======================================================================
function
lset.get( topRec, ldtBinName, searchValue, userModule, filter, fargs, src )
  GP=B and trace("\n\n  >>>>>>>>>>>>> API[ GET ] <<<<<<<<<<<<<<<<<< \n");

  local meth = "lset.get()";
  GP=E and trace("[ENTER]: <%s:%s> Bin(%s) Search Value(%s)",
     MOD, meth, tostring( ldtBinName), tostring( searchValue ) );

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  -- local ldtCtrl = topRec[ldtBinName];
  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];
  local resultObject = 0;
  
  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- Get the value we'll compare against (either a subset of the object,
  -- or the object "string-ified"
  local key = getKeyValue( ldtMap, searchValue );

  -- Set up our global "UnTransform" and Filter Functions.  This lets us
  -- process the function pointers once per call, and consistently for
  -- all LSET operations.
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, false, G_KeyFunction );
  G_Filter, G_UnTransform =
    ldt_common.setReadFunctions( ldtMap, userModule, filter );
  G_FunctionArgs = fargs;

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Use the SubRec style Search
    resultObject = subRecSearch( src, topRec, ldtCtrl, key );
  else
    -- Use the TopRec style Search (this is default if the subrec style
    -- is not specifically requested).
    resultObject = topRecSearch( topRec, ldtCtrl, key );
  end

  -- Report an error if we did not find the object.
  if( resultObject == nil ) then
    info("[NOT FOUND]<%s:%s> SearchValue(%s)",MOD,meth,tostring(searchValue));
    error(ldte.ERR_NOT_FOUND);
  end

  GP=E and trace("[EXIT]<%s:%s> Result(%s)",MOD,meth,tostring(resultObject));
  return resultObject;
end -- function lset.get()

-- ======================================================================
-- lset.exists()
-- ======================================================================
-- Return value 1 (ONE) if the item exists in the set, otherwise return 0.
-- We don't want to return "true" and "false" because of Lua Weirdness.
-- Note that this looks a LOT like lset.get(), except that we don't
-- return the object, nor do we apply a filter.
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) searchValue:
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- ======================================================================
function lset.exists( topRec, ldtBinName, searchValue, src )
  GP=B and trace("\n\n  >>>>>>>>>>>>> API[ EXISTS ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "lset.exists()";
  GP=E and trace("[ENTER]: <%s:%s> Search Value(%s)",
                 MOD, meth, tostring( searchValue ) );

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];
  local resultObject = 0;
 
  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- Get the value we'll compare against (either a subset of the object,
  -- or the object "string-ified"
  local key = getKeyValue( ldtMap, searchValue );

  -- Set up our global "UnTransform" and Filter Functions. This lets us
  -- process the function pointers once per call, and consistently for
  -- all LSET operations. (However, filter not used here.)
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, false, G_KeyFunction );
  G_Filter, G_UnTransform = ldt_common.setReadFunctions( ldtMap, nil, nil );

  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Use the SubRec style Search
    resultObject = subRecSearch( src, topRec, ldtCtrl, key );
  else
    -- Use the TopRec style Search (this is default if the subrec style
    -- is not specifically requested).
    resultObject = topRecSearch( topRec, ldtCtrl, key );
  end

  local result = 1; -- be positive.
  if( resultObject == nil ) then
    result = 0;
  end

  GP=E and trace("[EXIT]: <%s:%s>: Exists Result(%d)",MOD, meth, result ); 
  return result;
end -- function lset.exists()

-- ======================================================================
-- lset.scan() -- Return a list containing ALL of LSET (with possible filter)
-- ======================================================================
-- Scan the entire LSET, and pass the entire set of objects thru a filter
-- (if present).  Return all objects that qualify.
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) userModule: (optional) Lua file containing user's filter function
-- (*) filter: (optional) User's Filter Function
-- (*) fargs: (optional) filter arguments
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- ======================================================================
function lset.scan(topRec, ldtBinName, userModule, filter, fargs, src)
  local meth = "lset.scan()";
  GP=B and trace("\n\n  >>>>>>>>>>>>> API[ SCAN ] <<<<<<<<<<<<<<<<<< \n");

  rc = 0; -- start out OK.
  GP=E and trace("[ENTER]<%s:%s> BinName(%s) Module(%s) Filter(%s) Fargs(%s)",
    MOD, meth, tostring(ldtBinName), tostring(userModule), tostring(filter),
    tostring(fargs));

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  -- Find the appropriate bin for the Search value
  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];
  local resultList = list();

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end
  
  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- Set up our global "UnTransform" and Filter Functions.
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, false, G_KeyFunction );
  G_Filter, G_UnTransform =
    ldt_common.setReadFunctions( ldtMap, userModule, filter );
  G_FunctionArgs = fargs;
  
  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Use the SubRec style scan
    subRecScan( src, topRec, ldtCtrl, resultList );
  else
    -- Use the TopRec style Scan (this is default Mode if the subrec style
    -- is not specifically requested).
    topRecScan( topRec, ldtCtrl, resultList );
  end

  GP=E and trace("[EXIT]: <%s:%s>: Search Returns (%s) Size : %d",
                 MOD, meth, tostring(resultList), list.size(resultList));

  return resultList; 
end -- function lset.scan()

-- ======================================================================
-- lset.remove() -- Remove an item from the LSET.
-- ======================================================================
-- Find an element (i.e. search) and then remove it from the list.
-- Return the element if found, return nil if not found.
-- Parms:
-- (*) topRec:
-- (*) ldtBinName:
-- (*) deleteValue:
-- (*) UserModule
-- (*) filter: the NAME of the filter function (which we'll find in FuncTable)
-- (*) fargs: Arguments to feed to the filter
-- (*) returnVal: When true, return the deleted value.
-- (*) src: Sub-Rec Context - Needed for repeated calls from caller
-- ======================================================================
function lset.remove( topRec, ldtBinName, deleteValue, userModule,
                                filter, fargs, returnVal, src )
  GP=B and trace("\n\n  >>>>>>>>>> > API [ REMOVE ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "lset.remove()";
  GP=E and trace("[ENTER]: <%s:%s> Delete Value(%s)",
                 MOD, meth, tostring( deleteValue ) );

  local rc = 0; -- Start out ok.

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  local propMap = ldtCtrl[1]; 
  local ldtMap = ldtCtrl[2];
  local resultObject;

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- Get the value we'll compare against
  local key = getKeyValue( ldtMap, deleteValue );

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- Set up our global "UnTransform" and Filter Functions.
  G_KeyFunction = ldt_common.setKeyFunction( ldtMap, false, G_KeyFunction );
  G_Filter, G_UnTransform =
    ldt_common.setReadFunctions( ldtMap, userModule, filter );
  G_FunctionArgs = fargs;
  
  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Use the SubRec style delete
    resultObject = subRecDelete( src, topRec, ldtCtrl, key, returnVal);
  else
    -- Use the TopRec style delete
    resultObject = topRecDelete( topRec, ldtCtrl, key, returnVal );
  end

  -- Update the Count, then update the Record.
  local itemCount = propMap[PM_ItemCount];
  propMap[PM_ItemCount] = itemCount - 1;
  topRec[ldtBinName] = ldtCtrl;
  record.set_flags(topRec, ldtBinName, BF_LDT_BIN );--Must set every time

  rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=E and trace("[EXIT]<%s:%s>: Success: DeleteValue(%s) Res(%s) binList(%s)",
    MOD, meth, tostring( deleteValue ), tostring(resultFiltered),
    tostring(binList));
  if( returnVal == true ) then
    return resultObject;
  end

  return 0;
end -- function lset.remove()

-- ========================================================================
-- lset.destroy() -- Remove the LDT entirely from the record.
-- ========================================================================
-- Release all of the storage associated with this LDT and remove the
-- control structure of the bin.  If this is the LAST LDT in the record,
-- then ALSO remove the HIDDEN LDT CONTROL BIN.
-- ==>  Remove the ESR, Null out the topRec bin.  The rest will happen
-- during NSUP cleanup.
--
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- (3) src: Sub-Rec Context - Needed for repeated calls from caller
-- Result:
--   res = 0: all is well
--   res = -1: Some sort of error
-- ========================================================================
-- NOTE: This could eventually be moved to COMMON, and be "localLdtDestroy()",
-- since it will work the same way for all LDTs.
-- Remove the ESR, Null out the topRec bin.
-- ALTHOUGH -- the MAIN MEMORY version of LSET needs special attention,
-- since we need to NULL out the bin lists.
-- ========================================================================
function lset.destroy( topRec, ldtBinName, src )
  GP=B and trace("\n\n  >>>>>>>>>> > API [ DESTROY ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "lset.destroy()";

  GP=E and trace("[ENTER]: <%s:%s> ldtBinName(%s)",
    MOD, meth, tostring(ldtBinName));
  local rc = 0; -- start off optimistic

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- Init our subrecContext, if necessary.  The SRC tracks all open
  -- SubRecords during the call. Then, allows us to close them all at the end.
  -- For the case of repeated calls from Lua, the caller must pass in
  -- an existing SRC that lives across LDT calls.
  if ( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- Get the Common LDT (Hidden) bin, and update the LDT count.  If this
  -- is the LAST LDT in the record, then remove the Hidden Bin entirely.
  local recPropMap = topRec[REC_LDT_CTRL_BIN];
  if( recPropMap == nil or recPropMap[RPM_Magic] ~= MAGIC ) then
    warn("[INTERNAL ERROR]<%s:%s> Prop Map for LDT Hidden Bin invalid",
      MOD, meth );
    error( ldte.ERR_INTERNAL );
  end
  local ldtCount = recPropMap[RPM_LdtCount];
  if( ldtCount <= 1 ) then
    -- This is the last LDT -- remove the LDT Control Property Bin
    topRec[REC_LDT_CTRL_BIN] = nil;
  else
    recPropMap[RPM_LdtCount] = ldtCount - 1;
    topRec[REC_LDT_CTRL_BIN] = recPropMap;
    record.set_flags(topRec, REC_LDT_CTRL_BIN, BF_LDT_HIDDEN );
  end

  if(ldtMap[M_SetTypeStore] ~= nil and ldtMap[M_SetTypeStore] == ST_SUBRECORD)
  then
    -- Use the SubRec style Destroy
    resultObject = subRecDestroy( src, topRec, ldtCtrl );
  else
    -- Use the TopRec style Destroy (this is default if the subrec style
    -- is not specifically requested).
    resultObject = topRecDestroy( topRec, ldtCtrl );
  end

  -- Update the Top Record.  Not sure if this returns nil or ZERO for ok,
  -- so just turn any NILs into zeros.
  rc = aerospike:update( topRec );
  if ( rc ~= 0 ) then
    warn("[ERROR]<%s:%s>TopRec Update Error rc(%s)",MOD,meth,tostring(rc));
    error( ldte.ERR_TOPREC_UPDATE );
  end 

  GP=E and trace("[Normal EXIT]:<%s:%s> Return(0)", MOD, meth );
  return 0;
end -- function lset.destroy()

-- ========================================================================
-- lset.size() -- return the number of elements (item count) in the LDT.
-- ========================================================================
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- Result:
--   res = size is greater or equal to 0.
--   res = -1: Some sort of error
-- ========================================================================
function lset.size( topRec, ldtBinName )
  GP=B and trace("\n\n  >>>>>>>>>> > API [ SIZE ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "lset_size()";
  GP=E and trace("[ENTER]: <%s:%s> ldtBinName(%s)",
  MOD, meth, tostring(ldtBinName));

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  local propMap = ldtCtrl[1];
  local ldtMap  = ldtCtrl[2];

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  local itemCount = propMap[PM_ItemCount];

  GP=E and trace("[EXIT]: <%s:%s> : size(%d)", MOD, meth, itemCount );

  return itemCount;
end -- function lset.size()

-- ========================================================================
-- lset.config() -- return the config settings
-- ========================================================================
-- Parms:
-- (1) topRec: the user-level record holding the LSET Bin
-- (2) ldtBinName: The name of the LSET Bin
-- Result:
--   res = Map of config settings
--   res = -1: Some sort of error
-- ========================================================================
function lset.config( topRec, ldtBinName )
  GP=B and trace("\n\n  >>>>>>>>>> > API [ CONFIG ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "lset.config()";

  GP=E and trace("[ENTER]: <%s:%s> ldtBinName(%s)",
      MOD, meth, tostring(ldtBinName));

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  local config = ldtSummary( ldtCtrl );

  GP=E and trace("[EXIT]:<%s:%s>:config(%s)", MOD, meth, tostring(config));

  return config;
end -- function lset.config()

-- ========================================================================
-- lset.get_capacity() -- return the current capacity setting for this LDT
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- Result:
--   rc >= 0  (the current capacity)
--   rc < 0: Aerospike Errors
-- ========================================================================
function lset.get_capacity( topRec, ldtBinName )
  local meth = "lset.get_capacity()";

  GP=E and trace("[ENTER]: <%s:%s> ldtBinName(%s)",
    MOD, meth, tostring(ldtBinName));

  -- validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  local ldtMap = ldtCtrl[2];

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  local capacity = ldtMap[M_StoreLimit];
  if( capacity == nil ) then
    capacity = 0;
  end

  GP=E and trace("[EXIT]: <%s:%s> : size(%d)", MOD, meth, capacity );

  return capacity;
end -- function lset.get_capacity()

-- ========================================================================
-- lset.setCapacity() -- set the current capacity setting for this LDT
-- ========================================================================
-- Parms:
-- (1) topRec: the user-level record holding the LDT Bin
-- (2) ldtBinName: The name of the LDT Bin
-- Result:
--   rc >= 0  (the current capacity)
--   rc < 0: Aerospike Errors
-- ========================================================================
function lset.setCapacity( topRec, ldtBinName, capacity )
  local meth = "lset.lsetCapacity()";

  GP=E and trace("[ENTER]: <%s:%s> ldtBinName(%s)",
    MOD, meth, tostring(ldtBinName));

  -- validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );

  -- For debugging, print out our main control map.
  GD=DEBUG and ldtDebugDump( ldtCtrl );

  -- Extract the LDT map from the LDT CONTROL.
  local ldtMap = ldtCtrl[2];
  if( capacity ~= nil and type(capacity) == "number" and capacity >= 0 ) then
    ldtMap[M_StoreLimit] = capacity;
  else
    warn("[ERROR]<%s:%s> Bad Capacity Value(%s)",MOD,meth,tostring(capacity));
    error( ldte.ERR_INTERNAL );
  end

  GP=E and trace("[EXIT]: <%s:%s> : new size(%d)", MOD, meth, capacity );

  return 0;
end -- function lset.lsetCapacity()

-- ========================================================================
-- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> 
-- Developer Functions
-- (*) dump()
-- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> -- <D> <D> <D> 
-- ========================================================================
--
-- ========================================================================
-- lset.dump()
-- ========================================================================
-- Dump the full contents of the LDT (structure and all).
-- shown in the result. Unlike scan which simply returns the contents of all 
-- the bins, this routine gives a tree-walk through or map walk-through of the
-- entire lset structure. 
-- Return a LIST of lists -- with Each List marked with it's Hash Name.
-- ========================================================================
function lset.dump( topRec, ldtBinName, src )
  GP=B and trace("\n\n  >>>>>>>> API[ DUMP ] <<<<<<<<<<<<<<<<<< \n");
  local meth = "dump()";
  GP=E and trace("[ENTER]<%s:%s> LDT BIN(%s)",MOD, meth, tostring(ldtBinName));

  -- set up the Sub-Rec Context, if needed.
  if( src == nil ) then
    src = ldt_common.createSubRecContext();
  end

  -- Validate the topRec, the bin and the map.  If anything is weird, then
  -- this will kick out with a long jump error() call.
  local ldtCtrl = validateRecBinAndMap( topRec, ldtBinName, true );
  localDump( src, topRec, ldtBinName ); -- Dump out our entire LDT structure.

  -- Another key difference between dump and scan : 
  -- dump prints things in the logs and returns a 0
  -- scan returns the list to the client/caller 

  local ret = " \n LDT bin contents dumped to server-logs \n"; 
  return ret; 
end -- function lset.dump();

-- ======================================================================
-- This is needed to export the function table for this module
-- Leave this statement at the end of the module.
-- ==> Define all functions before this end section.
-- ======================================================================
return lset;
-- ========================================================================
--   _      _____ _____ _____ 
--  | |    /  ___|  ___|_   _|
--  | |    \ `--.| |__   | |  
--  | |     `--. \  __|  | |  
--  | |____/\__/ / |___  | |  
--  \_____/\____/\____/  \_/  (LIB)
--                            
-- ========================================================================
-- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> --
