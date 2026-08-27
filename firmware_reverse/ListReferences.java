// Print all direct references to one or more firmware addresses.
//@category VietMap

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

public class ListReferences extends GhidraScript {
    @Override
    public void run() throws Exception {
        for (String value : getScriptArgs()) {
            Address address = toAddr(value);
            println("===== REFERENCES TO " + address + " =====");
            ReferenceIterator references = currentProgram.getReferenceManager().getReferencesTo(address);
            while (references.hasNext()) {
                Reference reference = references.next();
                println(reference.getFromAddress() + " " + reference.getReferenceType());
            }
        }
    }
}
