---
-- Implements a simple framer block which accepts a series of frame payloads
-- formatted as in:Byte. Inter-frame idle periods are indicated by byte values
-- of zero, and the first non-zero byte after the inter-frame idle period is
-- interpreted as a length byte which specifies the number of subsequent bytes
-- that form the message to be transmitted.
-- The output consists of frames formatted as follows:
--   Preamble       : 0xA5 0xF0 0xA5 0xF0 0xA5 0xF0
--   Start of frame : 0x7E 0x81 0xC3 0x3C
--   Frame length   : Number of bytes in body (excludes length and CRC bytes)
--   Payload        : Payload data (integer number of bytes, at least one)
--   Checksum       : Checksum over all payload bytes including the length byte
--                    using the 16-bit modulo 255 Fletcher checksum.
-- Frame outputs are a sequence of bytes where 0x00 and 0x01 represent valid
-- data bits and other values represent idle bits.
--
-- @category Protocol
-- @block SimpleFramerBlock
--
-- @signature in:Byte > out:Byte
--
-- @usage
-- local framer = radio.SimpleFramerBlock()

local bit = require('bit')

local block = require('radio.core.block')
local types = require('radio.types')

local SimpleFramerBlock = block.factory("SimpleFramerBlock")

function SimpleFramerBlock:instantiate()
    self:add_type_signature({block.Input("in", types.Byte)}, {block.Output("out", types.Byte)})
end

function SimpleFramerBlock:initialize()
    self.out = types.Byte.vector()
    self.idle = true
    self.byteCount = 0
    self.checksums = {0, 0}
end

function SimpleFramerBlock:get_rate()
    return block.Block.get_rate(self) * 8
end

local function sendDataByte (out, offset, byteData)
    local byteShift = byteData
    for i = 0, 7 do
        local bitValue = bit.band(byteShift,1)
        byteShift = bit.rshift(byteShift,1)
        out.data[8*offset+i] = types.Byte(bitValue)
    end
end

local function sendIdleByte (out, offset)
    for i = 0, 7 do
        out.data[8*offset+i] = types.Byte(0xFF)
    end
end

local function updateChecksum (checksums, byteData)
    checksums[1] = checksums[1] + byteData
    checksums[2] = checksums[2] + checksums[1]
    return checksums
end

function SimpleFramerBlock:process(x)
    local out = self.out:resize(x.length*8)
    local offset = 0

    for i = 0, x.length-1 do
        local thisByte = x.data[i]

        -- processes out of frame idle bytes until a size byte is detected
        if (self.idle) then
            if thisByte.value == 0x00 then
                -- idle insertion
                sendIdleByte(out, offset+i)
            else
                -- header insertion
                out = self.out:resize(self.out.length+80)
                sendDataByte(out, offset+i, 0xA5)
                sendDataByte(out, offset+i+1, 0xF0)
                sendDataByte(out, offset+i+2, 0xA5)
                sendDataByte(out, offset+i+3, 0xF0)
                sendDataByte(out, offset+i+4, 0xA5)
                sendDataByte(out, offset+i+5, 0xF0)
                sendDataByte(out, offset+i+6, 0x7E)
                sendDataByte(out, offset+i+7, 0x81)
                sendDataByte(out, offset+i+8, 0xC3)
                sendDataByte(out, offset+i+9, 0x3C)
                sendDataByte(out, offset+i+10, thisByte.value)
                offset = offset + 10
                self.idle = false
                self.byteCount = thisByte.value
                self.checksums = updateChecksum({0, 0}, thisByte.value)
            end

        -- processes frame payload data until the end of frame
        else
            sendDataByte (out, offset+i, thisByte.value)
            self.byteCount = self.byteCount - 1
            self.checksums = updateChecksum(self.checksums, thisByte.value)

            -- insert CRC at end of frame
            if self.byteCount == 0 then
                out = self.out:resize(self.out.length+32)
                sendDataByte(out, offset+i+1, self.checksums[1] % 255)
                sendDataByte(out, offset+i+2, self.checksums[2] % 255)
                sendIdleByte(out, offset+i+3)
                sendIdleByte(out, offset+i+4)
                offset = offset + 4
                self.idle = true
            end
        end
    end

    return out
end

return SimpleFramerBlock
