from buildbot.steps.source import SVN
from buildbot.steps.shell import SetProperty
from buildbot.steps.shell import ShellCommand
from buildbot.steps.shell import WarningCountingShellCommand
from buildbot.process.factory import BuildFactory
from buildbot.process.properties import WithProperties
from zorg.buildbot.commands.NinjaCommand import NinjaCommand

def get3StageClangLTOBuildFactory(
           clean=True,
           env=None,
           build_gold=False,
           cmake_cache_file=None,
           extra_cmake_options=None,
    ):

    llvm_srcdir = "llvm.src"
    llvm_objdir = "llvm-stage1.obj"

    merged_env = {
        'TERM' : 'dumb' # Make sure Clang doesn't use color escape sequences.
    }
    if env is not None:
        merged_env.update(env)

    f = BuildFactory()

    f.addStep(
        SVN(
            name='svn-llvm',
            mode='update',
            baseURL='http://llvm.org/svn/llvm-project/llvm/',
            defaultBranch='trunk',
            workdir=llvm_srcdir
        )
    )

    f.addStep(
        SVN(
            name='svn-clang',
            mode='update',
            baseURL='http://llvm.org/svn/llvm-project/cfe/',
            defaultBranch='trunk',
            workdir='%s/tools/clang' % llvm_srcdir
        )
    )

    # We have to programatically determine the current llvm version.
    f.addStep(
        SetProperty(
            name="get_llvm_ver",
            command=["grep 'release =' %s/tools/clang/docs/conf.py | awk '{print $3;}' | sed \"s/'//g\"" % llvm_srcdir],
            property="llvm_ver",
            description="get llvm release ver",
            workdir=llvm_srcdir,
            env=merged_env
        )
    )

    # Clean directory, if requested.
    cleanBuildRequested = lambda step: step.build.getProperty("clean") or clean
    f.addStep(
        ShellCommand(
            doStepIf=cleanBuildRequested,
            name="rm-llvm_objdir",
            command=["rm", "-rf", llvm_objdir],
            haltOnFailure=True,
            description=["rm build dir", "llvm"],
            workdir=".",
            env=merged_env
        )
    )

    cmake_command = ["cmake"]
    
    if cmake_cache_file:
        cmake_command += "-C %s" % (" ".join(cmake_cache_file))

    if extra_cmake_options:
        cmake_command += extra_cmake_options

    cmake_command += [
        "../%s" % llvm_srcdir
    ]

    # Note: ShellCommand does not pass the params with special symbols right.
    # The " ".join is a workaround for this bug.
    f.addStep(
        WarningCountingShellCommand(
            name="cmake-configure",
            description=["cmake configure"],
            haltOnFailure=True,
            command=WithProperties(" ".join(cmake_command)),
            workdir=llvm_objdir,
            env=merged_env
        )
    )

    if build_gold:
        f.addStep(
            NinjaCommand(name='build',
                targets=['lib/LLVMgold.so'],
                haltOnFailure=True,
                warnOnWarnings=True,
                description=["3 Stage Build Clang"],
                workdir=llvm_objdir,
                env=merged_env)
        )

    f.addStep(
        NinjaCommand(name='build',
            targets=['stage3-clang'],
            haltOnFailure=True,
            warnOnWarnings=True,
            description=["3 Stage Build Clang"],
            workdir=llvm_objdir,
            env=merged_env)
    )

    f.addStep(
        NinjaCommand(name='build',
            targets=['stage3-check-clang'],
            haltOnFailure=True,
            warnOnWarnings=True,
            description=["Check Clang"],
            workdir=llvm_objdir,
            env=merged_env)
    )

    # Compare stage2 & stage3 clang
    shell_command = ["diff", "-q", "tools/clang/stage2-bins/bin/clang-%(llvm_ver)s", "tools/clang/stage2-bins/tools/clang/stage3-bins/bin/clang-%(llvm_ver)s"]
    f.addStep(
        ShellCommand(
            name="compare",
            description=["comapre stage2 & stage3 clang"],
            haltOnFailure=True,
            command=WithProperties(" ".join(shell_command)),
            workdir=llvm_objdir,
            env=merged_env
        )
    )

    return f
