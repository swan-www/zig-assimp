const std = @import("std");
const builtin = @import("builtin");

const zig_version = builtin.zig_version;
fn lazy_from_path(path_chars: []const u8, owner: *std.Build) std.Build.LazyPath {
    if (zig_version.major > 0 or zig_version.minor >= 13) {
        return std.Build.LazyPath{ .src_path = .{ .sub_path = path_chars, .owner = owner } };
    } else if (zig_version.minor >= 12) {
        return std.Build.LazyPath{ .path = path_chars };
    } else unreachable;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const formats = b.option([]const u8, "formats", "Comma separated list of enabled formats or \"all\", for example: STL,3MF,Obj") orelse "";
    const use_double_precision = b.option(bool, "double", "All data will be stored as double values") orelse false;
    const assimp = b.dependency("assimp", .{});

    //Set the output directory to use a per-target folder
    const joined_target_str = try std.mem.concat(b.allocator, u8, &.{ @tagName(target.result.cpu.arch), "_", @tagName(target.result.os.tag), "_", @tagName(target.result.abi) });
    b.lib_dir = try std.fs.path.join(b.allocator, &.{ b.install_path, joined_target_str, "lib" });
    b.h_dir = try std.fs.path.join(b.allocator, &.{ b.install_path, joined_target_str, "include" });
    b.exe_dir = try std.fs.path.join(b.allocator, &.{ b.install_path, joined_target_str, "bin" });
    b.dest_dir = try std.fs.path.join(b.allocator, &.{ b.install_path, joined_target_str });

    const lib = b.addStaticLibrary(.{
        .name = "assimp",
        .optimize = optimize,
        .target = target,
    });

    if (target.result.os.tag == .windows) {
        lib.defineCMacro("_WINDOWS", null);
        lib.defineCMacro("_WIN32", null);
        lib.defineCMacro("OPENDDL_STATIC_LIBARY", null);
        lib.defineCMacro("ASSIMP_IMPORTER_GLTF_USE_OPEN3DGC", "1");
    }

    lib.linkLibC();
    if (target.result.abi != .msvc) {
        lib.linkLibCpp();
    }

    const config_h = b.addConfigHeader(
        .{
            .style = .{ .cmake = assimp.path("include/assimp/config.h.in") },
            .include_path = "assimp/config.h",
        },
        .{ .ASSIMP_DOUBLE_PRECISION = use_double_precision },
    );
    lib.addConfigHeader(config_h);
    lib.addIncludePath(assimp.path("include"));
    lib.addIncludePath(lazy_from_path("include", b));

    lib.addIncludePath(assimp.path(""));
    lib.addIncludePath(assimp.path("contrib"));
    lib.addIncludePath(assimp.path("code"));
    lib.addIncludePath(assimp.path("contrib/pugixml/src/"));
    lib.addIncludePath(assimp.path("contrib/rapidjson/include"));
    lib.addIncludePath(assimp.path("contrib/unzip"));
    lib.addIncludePath(assimp.path("contrib/zlib"));
    lib.addIncludePath(assimp.path("contrib/openddlparser/include"));

    lib.defineCMacro("RAPIDJSON_HAS_STDSTRING", "1");

    lib.installConfigHeader(config_h);
    lib.installHeadersDirectory(
        assimp.path("include"),
        "",
        .{ .include_extensions = &.{ ".h", ".inl", ".hpp" } },
    );

    lib.installHeadersDirectory(
        lazy_from_path("include", b),
        "",
        .{ .include_extensions = &.{ ".h", ".inl", ".hpp" } },
    );

    lib.addCSourceFiles(.{
        .root = assimp.path(""),
        .files = &sources.common,
        .flags = &.{},
    });

    inline for (comptime std.meta.declarations(sources.libraries)) |ext_lib| {
        lib.addCSourceFiles(.{
            .root = assimp.path(""),
            .files = &@field(sources.libraries, ext_lib.name),
            .flags = &.{},
        });
    }

    var enable_all = false;
    var enabled_formats = std.BufSet.init(b.allocator);
    defer enabled_formats.deinit();
    var tokenizer = std.mem.tokenize(u8, formats, ",");
    while (tokenizer.next()) |format| {
        if (std.mem.eql(u8, format, "all")) {
            enable_all = true;
            break;
        }

        var found: bool = false;
        inline for (comptime std.meta.declarations(sources.formats)) |format_files| {
            if (std.mem.eql(u8, format_files.name, format)) {
                try enabled_formats.insert(format);
                found = true;
            }
        }
        if (!found) {
            std.debug.print("Unsupported format: {s}\n", .{format});
            std.debug.print("Supported formats:\n", .{});
            inline for (comptime std.meta.declarations(sources.formats)) |format_files| {
                std.debug.print("    {s}\n", .{format_files.name});
            }
            return error.InvalidFormat;
        }
    }

    inline for (comptime std.meta.declarations(sources.formats)) |format_files| {
        const enabled = enable_all or enabled_formats.contains(format_files.name);

        if (enabled) {
            lib.addCSourceFiles(.{
                .root = assimp.path(""),
                .files = &@field(sources.formats, format_files.name),
                .flags = &.{},
            });
        } else {
            const define_importer = b.fmt("ASSIMP_BUILD_NO_{}_IMPORTER", .{fmtUpperCase(format_files.name)});
            const define_exporter = b.fmt("ASSIMP_BUILD_NO_{}_EXPORTER", .{fmtUpperCase(format_files.name)});

            lib.defineCMacro(define_importer, null);
            lib.defineCMacro(define_exporter, null);
        }
    }

    for (unsupported_formats) |unsupported_format| {
        const define_importer = b.fmt("ASSIMP_BUILD_NO_{}_IMPORTER", .{fmtUpperCase(unsupported_format)});
        const define_exporter = b.fmt("ASSIMP_BUILD_NO_{}_EXPORTER", .{fmtUpperCase(unsupported_format)});

        lib.defineCMacro(define_importer, null);
        lib.defineCMacro(define_exporter, null);
    }

    b.installArtifact(lib);

    lib.installHeader(b.path("LICENCE"), "../lib/ZIG_ASSIMP_LICENSE");
    lib.installHeader(assimp.path("LICENSE"), "../lib/ASSIMP_LICENSE");
    lib.installHeader(assimp.path("test/models-nonbsd/Ogre/OgreSDK/LICENSE"), "../lib/OGRESDK_LICENSE");
    lib.installHeader(assimp.path("contrib/zlib/LICENSE"), "../lib/zlib_LICENSE");
    lib.installHeader(assimp.path("contrib/utf8cpp/doc/LICENSE"), "../lib/utf8cpp_LICENSE");
    lib.installHeader(assimp.path("contrib/rapidjson/license.txt"), "../lib/rapidjson_LICENSE.txt");
    lib.installHeader(assimp.path("contrib/poly2tri/LICENSE"), "../lib/poly2tri_LICENSE");
    lib.installHeader(assimp.path("contrib/openddlparser/LICENSE"), "../lib/openddlparser_LICENSE");
    lib.installHeader(assimp.path("contrib/draco/LICENSE"), "../lib/draco_LICENSE");
    lib.installHeader(assimp.path("contrib/clipper/License.txt"), "../lib/clipper_LICENSE.txt");
}

const unsupported_formats = [_][]const u8{
    "C4D", // fails to build, MSVC only
};

const sources = struct {
    const common = [_][]const u8{
        "code/CApi/AssimpCExport.cpp",
        "code/CApi/CInterfaceIOWrapper.cpp",
        "code/Common/AssertHandler.cpp",
        "code/Common/Assimp.cpp",
        "code/Common/Base64.cpp",
        "code/Common/BaseImporter.cpp",
        "code/Common/BaseProcess.cpp",
        "code/Common/Bitmap.cpp",
        "code/Common/CreateAnimMesh.cpp",
        "code/Common/Compression.cpp",
        "code/Common/DefaultIOStream.cpp",
        "code/Common/IOSystem.cpp",
        "code/Common/DefaultIOSystem.cpp",
        "code/Common/DefaultLogger.cpp",
        "code/Common/Exceptional.cpp",
        "code/Common/Exporter.cpp",
        "code/Common/Importer.cpp",
        "code/Common/ImporterRegistry.cpp",
        "code/Common/material.cpp",
        "code/Common/PostStepRegistry.cpp",
        "code/Common/RemoveComments.cpp",
        "code/Common/scene.cpp",
        "code/Common/SceneCombiner.cpp",
        "code/Common/ScenePreprocessor.cpp",
        "code/Common/SGSpatialSort.cpp",
        "code/Common/simd.cpp",
        "code/Common/SkeletonMeshBuilder.cpp",
        "code/Common/SpatialSort.cpp",
        "code/Common/StandardShapes.cpp",
        "code/Common/Subdivision.cpp",
        "code/Common/TargetAnimation.cpp",
        "code/Common/Version.cpp",
        "code/Common/VertexTriangleAdjacency.cpp",
        "code/Common/ZipArchiveIOSystem.cpp",
        "code/Geometry/GeometryUtils.cpp",
        "code/Material/MaterialSystem.cpp",
        "code/Pbrt/PbrtExporter.cpp",
        "code/PostProcessing/ArmaturePopulate.cpp",
        "code/PostProcessing/CalcTangentsProcess.cpp",
        "code/PostProcessing/ComputeUVMappingProcess.cpp",
        "code/PostProcessing/ConvertToLHProcess.cpp",
        "code/PostProcessing/DeboneProcess.cpp",
        "code/PostProcessing/DropFaceNormalsProcess.cpp",
        "code/PostProcessing/EmbedTexturesProcess.cpp",
        "code/PostProcessing/FindDegenerates.cpp",
        "code/PostProcessing/FindInstancesProcess.cpp",
        "code/PostProcessing/FindInvalidDataProcess.cpp",
        "code/PostProcessing/FixNormalsStep.cpp",
        "code/PostProcessing/GenBoundingBoxesProcess.cpp",
        "code/PostProcessing/GenFaceNormalsProcess.cpp",
        "code/PostProcessing/GenVertexNormalsProcess.cpp",
        "code/PostProcessing/ImproveCacheLocality.cpp",
        "code/PostProcessing/JoinVerticesProcess.cpp",
        "code/PostProcessing/LimitBoneWeightsProcess.cpp",
        "code/PostProcessing/MakeVerboseFormat.cpp",
        "code/PostProcessing/OptimizeGraph.cpp",
        "code/PostProcessing/OptimizeMeshes.cpp",
        "code/PostProcessing/PretransformVertices.cpp",
        "code/PostProcessing/ProcessHelper.cpp",
        "code/PostProcessing/RemoveRedundantMaterials.cpp",
        "code/PostProcessing/RemoveVCProcess.cpp",
        "code/PostProcessing/ScaleProcess.cpp",
        "code/PostProcessing/SortByPTypeProcess.cpp",
        "code/PostProcessing/SplitByBoneCountProcess.cpp",
        "code/PostProcessing/SplitLargeMeshes.cpp",
        "code/PostProcessing/TextureTransform.cpp",
        "code/PostProcessing/TriangulateProcess.cpp",
        "code/PostProcessing/ValidateDataStructure.cpp",
    };

    const libraries = struct {
        pub const unzip = [_][]const u8{
            "contrib/unzip/unzip.c",
            "contrib/unzip/ioapi.c",
            // "contrib/unzip/crypt.c",
        };
        pub const zip = [_][]const u8{
            "contrib/zip/src/zip.c",
        };
        pub const zlib = [_][]const u8{
            "contrib/zlib/inflate.c",
            "contrib/zlib/infback.c",
            "contrib/zlib/gzclose.c",
            "contrib/zlib/gzread.c",
            "contrib/zlib/inftrees.c",
            "contrib/zlib/gzwrite.c",
            "contrib/zlib/compress.c",
            "contrib/zlib/inffast.c",
            "contrib/zlib/uncompr.c",
            "contrib/zlib/gzlib.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/testzlib/testzlib.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/inflate86/inffas86.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/masmx64/inffas8664.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/infback9/infback9.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/infback9/inftree9.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/minizip/miniunz.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/minizip/minizip.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/minizip/unzip.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/minizip/ioapi.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/minizip/mztools.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/minizip/zip.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/minizip/iowin32.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/puff/pufftest.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/puff/puff.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/blast/blast.c",
            // assimpRoot() ++ "/contrib/zlib/contrib/untgz/untgz.c",
            "contrib/zlib/trees.c",
            "contrib/zlib/zutil.c",
            "contrib/zlib/deflate.c",
            "contrib/zlib/crc32.c",
            "contrib/zlib/adler32.c",
        };
        pub const poly2tri = [_][]const u8{
            "contrib/poly2tri/poly2tri/common/shapes.cc",
            "contrib/poly2tri/poly2tri/sweep/sweep_context.cc",
            "contrib/poly2tri/poly2tri/sweep/advancing_front.cc",
            "contrib/poly2tri/poly2tri/sweep/cdt.cc",
            "contrib/poly2tri/poly2tri/sweep/sweep.cc",
        };
        pub const clipper = [_][]const u8{
            "contrib/clipper/clipper.cpp",
        };
        pub const openddlparser = [_][]const u8{
            "contrib/openddlparser/code/OpenDDLParser.cpp",
            "contrib/openddlparser/code/OpenDDLExport.cpp",
            "contrib/openddlparser/code/DDLNode.cpp",
            "contrib/openddlparser/code/OpenDDLCommon.cpp",
            "contrib/openddlparser/code/Value.cpp",
            "contrib/openddlparser/code/OpenDDLStream.cpp",
        };
    };
    pub const formats = struct {
        pub const @"3DS" = [_][]const u8{
            "code/AssetLib/3DS/3DSConverter.cpp",
            "code/AssetLib/3DS/3DSExporter.cpp",
            "code/AssetLib/3DS/3DSLoader.cpp",
        };
        pub const @"3MF" = [_][]const u8{
            "code/AssetLib/3MF/D3MFExporter.cpp",
            "code/AssetLib/3MF/D3MFImporter.cpp",
            "code/AssetLib/3MF/D3MFOpcPackage.cpp",
            "code/AssetLib/3MF/XmlSerializer.cpp",
        };
        pub const AC = [_][]const u8{
            "code/AssetLib/AC/ACLoader.cpp",
        };
        pub const AMF = [_][]const u8{
            "code/AssetLib/AMF/AMFImporter_Geometry.cpp",
            "code/AssetLib/AMF/AMFImporter_Material.cpp",
            "code/AssetLib/AMF/AMFImporter_Postprocess.cpp",
            "code/AssetLib/AMF/AMFImporter.cpp",
        };
        pub const ASE = [_][]const u8{
            "code/AssetLib/ASE/ASELoader.cpp",
            "code/AssetLib/ASE/ASEParser.cpp",
        };
        pub const Assbin = [_][]const u8{
            "code/AssetLib/Assbin/AssbinExporter.cpp",
            "code/AssetLib/Assbin/AssbinFileWriter.cpp",
            "code/AssetLib/Assbin/AssbinLoader.cpp",
        };
        pub const Assjson = [_][]const u8{
            "code/AssetLib/Assjson/cencode.c",
            "code/AssetLib/Assjson/json_exporter.cpp",
            "code/AssetLib/Assjson/mesh_splitter.cpp",
        };
        pub const Assxml = [_][]const u8{
            "code/AssetLib/Assxml/AssxmlExporter.cpp",
            "code/AssetLib/Assxml/AssxmlFileWriter.cpp",
        };
        pub const B3D = [_][]const u8{
            "code/AssetLib/B3D/B3DImporter.cpp",
        };
        pub const Blend = [_][]const u8{
            "code/AssetLib/Blender/BlenderBMesh.cpp",
            "code/AssetLib/Blender/BlenderCustomData.cpp",
            "code/AssetLib/Blender/BlenderDNA.cpp",
            "code/AssetLib/Blender/BlenderLoader.cpp",
            "code/AssetLib/Blender/BlenderModifier.cpp",
            "code/AssetLib/Blender/BlenderScene.cpp",
            "code/AssetLib/Blender/BlenderTessellator.cpp",
        };
        pub const BVH = [_][]const u8{
            "code/AssetLib/BVH/BVHLoader.cpp",
        };
        // pub const C4D = [_][]const u8{
        //     "code/AssetLib/C4D/C4DImporter.cpp",
        // };
        pub const COB = [_][]const u8{
            "code/AssetLib/COB/COBLoader.cpp",
        };
        pub const Collada = [_][]const u8{
            "code/AssetLib/Collada/ColladaExporter.cpp",
            "code/AssetLib/Collada/ColladaHelper.cpp",
            "code/AssetLib/Collada/ColladaLoader.cpp",
            "code/AssetLib/Collada/ColladaParser.cpp",
        };
        pub const CSM = [_][]const u8{
            "code/AssetLib/CSM/CSMLoader.cpp",
        };
        pub const DXF = [_][]const u8{
            "code/AssetLib/DXF/DXFLoader.cpp",
        };
        pub const FBX = [_][]const u8{
            "code/AssetLib/FBX/FBXAnimation.cpp",
            "code/AssetLib/FBX/FBXBinaryTokenizer.cpp",
            "code/AssetLib/FBX/FBXConverter.cpp",
            "code/AssetLib/FBX/FBXDeformer.cpp",
            "code/AssetLib/FBX/FBXDocument.cpp",
            "code/AssetLib/FBX/FBXDocumentUtil.cpp",
            "code/AssetLib/FBX/FBXExporter.cpp",
            "code/AssetLib/FBX/FBXExportNode.cpp",
            "code/AssetLib/FBX/FBXExportProperty.cpp",
            "code/AssetLib/FBX/FBXImporter.cpp",
            "code/AssetLib/FBX/FBXMaterial.cpp",
            "code/AssetLib/FBX/FBXMeshGeometry.cpp",
            "code/AssetLib/FBX/FBXModel.cpp",
            "code/AssetLib/FBX/FBXNodeAttribute.cpp",
            "code/AssetLib/FBX/FBXParser.cpp",
            "code/AssetLib/FBX/FBXProperties.cpp",
            "code/AssetLib/FBX/FBXTokenizer.cpp",
            "code/AssetLib/FBX/FBXUtil.cpp",
        };
        pub const glTF = [_][]const u8{
            "code/AssetLib/glTF/glTFCommon.cpp",
            "code/AssetLib/glTF/glTFExporter.cpp",
            "code/AssetLib/glTF/glTFImporter.cpp",
        };
        pub const glTF2 = [_][]const u8{
            "code/AssetLib/glTF2/glTF2Exporter.cpp",
            "code/AssetLib/glTF2/glTF2Importer.cpp",
        };
        pub const HMP = [_][]const u8{
            "code/AssetLib/HMP/HMPLoader.cpp",
        };
        pub const IFC = [_][]const u8{
            "code/AssetLib/IFC/IFCBoolean.cpp",
            "code/AssetLib/IFC/IFCCurve.cpp",
            "code/AssetLib/IFC/IFCGeometry.cpp",
            "code/AssetLib/IFC/IFCLoader.cpp",
            "code/AssetLib/IFC/IFCMaterial.cpp",
            "code/AssetLib/IFC/IFCOpenings.cpp",
            "code/AssetLib/IFC/IFCProfile.cpp",
            // "code/AssetLib/IFC/IFCReaderGen_4.cpp", // not used?
            "code/AssetLib/IFC/IFCReaderGen1_2x3.cpp",
            "code/AssetLib/IFC/IFCReaderGen2_2x3.cpp",
            "code/AssetLib/IFC/IFCUtil.cpp",
        };
        pub const Irr = [_][]const u8{
            "code/AssetLib/Irr/IRRLoader.cpp",
            "code/AssetLib/Irr/IRRShared.cpp",
        };
        pub const IrrMesh = [_][]const u8{
            "code/AssetLib/Irr/IRRMeshLoader.cpp",
            "code/AssetLib/Irr/IRRShared.cpp",
        };
        pub const IQM = [_][]const u8{
            "code/AssetLib/IQM/IQMImporter.cpp",
        };
        pub const LWO = [_][]const u8{
            "code/AssetLib/LWO/LWOAnimation.cpp",
            "code/AssetLib/LWO/LWOBLoader.cpp",
            "code/AssetLib/LWO/LWOLoader.cpp",
            "code/AssetLib/LWO/LWOMaterial.cpp",
            "code/AssetLib/LWS/LWSLoader.cpp",
        };
        pub const LWS = [_][]const u8{
            "code/AssetLib/M3D/M3DExporter.cpp",
            "code/AssetLib/M3D/M3DImporter.cpp",
            "code/AssetLib/M3D/M3DWrapper.cpp",
        };
        pub const M3D = [_][]const u8{};
        pub const MD2 = [_][]const u8{
            "code/AssetLib/MD2/MD2Loader.cpp",
        };
        pub const MD3 = [_][]const u8{
            "code/AssetLib/MD3/MD3Loader.cpp",
        };
        pub const MD5 = [_][]const u8{
            "code/AssetLib/MD5/MD5Loader.cpp",
            "code/AssetLib/MD5/MD5Parser.cpp",
        };
        pub const MDC = [_][]const u8{
            "code/AssetLib/MDC/MDCLoader.cpp",
        };
        pub const MDL = [_][]const u8{
            "code/AssetLib/MDL/HalfLife/HL1MDLLoader.cpp",
            "code/AssetLib/MDL/HalfLife/UniqueNameGenerator.cpp",
            "code/AssetLib/MDL/MDLLoader.cpp",
            "code/AssetLib/MDL/MDLMaterialLoader.cpp",
        };
        pub const MMD = [_][]const u8{
            "code/AssetLib/MMD/MMDImporter.cpp",
            "code/AssetLib/MMD/MMDPmxParser.cpp",
        };
        pub const MS3D = [_][]const u8{
            "code/AssetLib/MS3D/MS3DLoader.cpp",
        };
        pub const NDO = [_][]const u8{
            "code/AssetLib/NDO/NDOLoader.cpp",
        };
        pub const NFF = [_][]const u8{
            "code/AssetLib/NFF/NFFLoader.cpp",
        };
        pub const Obj = [_][]const u8{
            "code/AssetLib/Obj/ObjExporter.cpp",
            "code/AssetLib/Obj/ObjFileImporter.cpp",
            "code/AssetLib/Obj/ObjFileMtlImporter.cpp",
            "code/AssetLib/Obj/ObjFileParser.cpp",
        };
        pub const OFF = [_][]const u8{
            "code/AssetLib/OFF/OFFLoader.cpp",
        };
        pub const Ogre = [_][]const u8{
            "code/AssetLib/Ogre/OgreBinarySerializer.cpp",
            "code/AssetLib/Ogre/OgreImporter.cpp",
            "code/AssetLib/Ogre/OgreMaterial.cpp",
            "code/AssetLib/Ogre/OgreStructs.cpp",
            "code/AssetLib/Ogre/OgreXmlSerializer.cpp",
        };
        pub const OpenGEX = [_][]const u8{
            "code/AssetLib/OpenGEX/OpenGEXExporter.cpp",
            "code/AssetLib/OpenGEX/OpenGEXImporter.cpp",
        };
        pub const Ply = [_][]const u8{
            "code/AssetLib/Ply/PlyExporter.cpp",
            "code/AssetLib/Ply/PlyLoader.cpp",
            "code/AssetLib/Ply/PlyParser.cpp",
        };
        pub const Q3BSP = [_][]const u8{
            "code/AssetLib/Q3BSP/Q3BSPFileImporter.cpp",
            "code/AssetLib/Q3BSP/Q3BSPFileParser.cpp",
        };
        pub const Q3D = [_][]const u8{
            "code/AssetLib/Q3D/Q3DLoader.cpp",
        };
        pub const Raw = [_][]const u8{
            "code/AssetLib/Raw/RawLoader.cpp",
        };
        pub const SIB = [_][]const u8{
            "code/AssetLib/SIB/SIBImporter.cpp",
        };
        pub const SMD = [_][]const u8{
            "code/AssetLib/SMD/SMDLoader.cpp",
        };
        pub const Step = [_][]const u8{
            "code/AssetLib/Step/StepExporter.cpp",
        };
        pub const STEPParser = [_][]const u8{
            "code/AssetLib/STEPParser/STEPFileEncoding.cpp",
            "code/AssetLib/STEPParser/STEPFileReader.cpp",
        };
        pub const STL = [_][]const u8{
            "code/AssetLib/STL/STLExporter.cpp",
            "code/AssetLib/STL/STLLoader.cpp",
        };
        pub const Terragen = [_][]const u8{
            "code/AssetLib/Terragen/TerragenLoader.cpp",
        };
        pub const @"3D" = [_][]const u8{
            "code/AssetLib/Unreal/UnrealLoader.cpp",
        };
        pub const X = [_][]const u8{
            "code/AssetLib/X/XFileExporter.cpp",
            "code/AssetLib/X/XFileImporter.cpp",
            "code/AssetLib/X/XFileParser.cpp",
        };
        pub const X3D = [_][]const u8{
            "code/AssetLib/X3D/X3DExporter.cpp",
            "code/AssetLib/X3D/X3DImporter.cpp",
            "code/AssetLib/X3D/X3DImporter.cpp",
            "code/AssetLib/X3D/X3DImporter_Geometry2D.cpp",
            "code/AssetLib/X3D/X3DImporter_Geometry3D.cpp",
            "code/AssetLib/X3D/X3DImporter_Group.cpp",
            "code/AssetLib/X3D/X3DImporter_Light.cpp",
            "code/AssetLib/X3D/X3DImporter_Metadata.cpp",
            "code/AssetLib/X3D/X3DImporter_Networking.cpp",
            "code/AssetLib/X3D/X3DImporter_Postprocess.cpp",
            "code/AssetLib/X3D/X3DImporter_Rendering.cpp",
            "code/AssetLib/X3D/X3DImporter_Shape.cpp",
            "code/AssetLib/X3D/X3DImporter_Texturing.cpp",
            "code/AssetLib/X3D/X3DGeoHelper.cpp",
            "code/AssetLib/X3D/X3DXmlHelper.cpp",
        };
        pub const XGL = [_][]const u8{
            "code/AssetLib/XGL/XGLLoader.cpp",
        };
    };
};

const UpperCaseFormatter = std.fmt.Formatter(struct {
    pub fn format(
        string: []const u8,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        var tmp: [256]u8 = undefined;
        var i: usize = 0;
        while (i < string.len) : (i += tmp.len) {
            try writer.writeAll(std.ascii.upperString(&tmp, string[i..@min(string.len, i + tmp.len)]));
        }
    }
}.format);

fn fmtUpperCase(string: []const u8) UpperCaseFormatter {
    return UpperCaseFormatter{ .data = string };
}
