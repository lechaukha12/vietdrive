// Decompile one or more firmware addresses supplied on the headless command line.
//@category VietMap

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class DecompileAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        for (String value : getScriptArgs()) {
            Address address = toAddr(value);
            Function function = currentProgram.getFunctionManager().getFunctionContaining(address);
            if (function == null) {
                println("NO_FUNCTION " + address);
                continue;
            }
            DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
            println("===== " + function.getName() + " @ " + function.getEntryPoint() + " =====");
            if (!result.decompileCompleted()) {
                println("DECOMPILE_FAILED " + result.getErrorMessage());
                continue;
            }
            println(result.getDecompiledFunction().getC());
        }
        decompiler.dispose();
    }
}
