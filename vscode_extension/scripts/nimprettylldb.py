import lldb

def NimStringSummary(value, internal_dict):
    length = value.GetChildMemberWithName("len").GetValueAsSigned()
    # Get the pointer to NimStrPayload
    payload_ptr = value.GetChildMemberWithName("p").GetValueAsUnsigned()
    if payload_ptr == 0 or length <= 0:
        return ""
    process = lldb.debugger.GetSelectedTarget().GetProcess()
    error = lldb.SBError()
    string_data = process.ReadMemory(payload_ptr + 8, length, error)  # +8 to skip the 'cap' field

    if error.Success():
        decoded_string = string_data.decode('utf-8', 'ignore')
        return '"{0}"'.format(decoded_string)
    else:
        return value
  
def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("type summary add -F " + __name__ + ".NimStringSummary NimStringV2")
 