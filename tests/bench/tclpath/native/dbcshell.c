/* tclsh with the dbcnative commands built in and, optionally (-DMODULE=name), a tcl-aot generated module registered as a static package. */
#include <tcl.h>
extern int Dbcnative_Init(Tcl_Interp *);
#ifdef MODULE
#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
#define STR2(a) #a
#define STR(a) STR2(a)
extern int CAT(MODULE, _Init)(Tcl_Interp *);
#endif
static int AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) != TCL_OK) return TCL_ERROR;
    if (Dbcnative_Init(interp) != TCL_OK) return TCL_ERROR;
#ifdef MODULE
    Tcl_StaticPackage(NULL, STR(MODULE), CAT(MODULE, _Init), NULL);
#endif
    return TCL_OK;
}
int main(int argc, char **argv) { Tcl_Main(argc, argv, AppInit); return 0; }
