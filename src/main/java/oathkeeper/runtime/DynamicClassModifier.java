package oathkeeper.runtime;

import javassist.CannotCompileException;
import javassist.ClassPool;
import javassist.CtClass;
import javassist.CtField;
import javassist.CtMethod;
import javassist.NotFoundException;
import javassist.expr.ExprEditor;
import javassist.expr.FieldAccess;
import oathkeeper.runtime.event.MarkerEvent;
import oathkeeper.runtime.event.OpTriggerEvent;
import oathkeeper.runtime.event.StateUpdateEvent;
import oathkeeper.runtime.eventlist.EventListBuilder;
import oathkeeper.runtime.gson.GsonUtils;
import oathkeeper.runtime.utils.BashUtil;
import org.reflections8.Reflections;
import org.reflections8.scanners.MemberUsageScanner;
import org.reflections8.scanners.SubTypesScanner;

import java.io.*;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.stream.Collectors;

/**
 * A helper class to instrument
 */
public class DynamicClassModifier {
    Map<String, String> stateFields = new HashMap<String, String>() {{

    }};
    Set<String> opInstClasses = new HashSet<String>() {{

    }};

    //since we only have one shot for each class, should group and do together
    Map<String, CtClass> toDumpClasses = new HashMap<>();

    private boolean ifClassMatchTargetTestClass(String cName)
    {
        String testName = System.getProperty("ok.testname");
        return testName != null && !testName.equals("") && cName.contains(testName);
    }

    private List<String> getClassesFromDiffFiles(String diffFiles)
    {
        List<String> lst = new ArrayList<>();

        String[] lines = diffFiles.split("\\r?\\n");

        for(String line: lines)
        {
            int index = line.lastIndexOf(".java");
            if(index==-1)
                continue;
            String result = line.substring(0,index)
                    .replace('/','.');
            int index2 = result.indexOf(ConfigManager.config.getString(ConfigManager.SYSTEM_PACKAGE_PREFIX_KEY));
            if(index2==-1)
                continue;
            String result2 = result.substring(index2);

            //we filter testing classes here
            if(result2.contains(".test."))
                continue;

            lst.add(result2);
        }
        return lst;
    }

    private String getPackageNameFromClassName(String className) {
        int iend = className.lastIndexOf(".");
        if (iend != -1) {
            String packageName = className.substring(0, iend);
            return packageName;
        }

        return null;
    }

    private void initFromDiffFileFromCommit(boolean appendUsage)
    {
        String diffFiles = System.getProperty("ok.filediff");
        System.out.println("diffFiles: "+diffFiles);
        if(diffFiles == null || diffFiles.equals(""))
        {
            return;
        }

        for(String clazz: getClassesFromDiffFiles(diffFiles))
        {
            String prefix = getPackageNameFromClassName(clazz);
            if(prefix==null)
                continue;

            Reflections reflections = new Reflections(prefix, new SubTypesScanner(false));

            Set<String> allClasses  = reflections.getAllTypes();
            for(String clazz2:allClasses)
            {
                opInstClasses.add(clazz2);
                System.out.println("Append to-instrument classes "+clazz2+" from git diff");
            }

            //used in relaxed mode, we add usage as well
            if(appendUsage)
            {
                for(String clazz2: scanImportedClassesFromDiffFile(clazz))
                {
                    String clazz2_processed = clazz2.replace("import ","").replace(";","");
                    opInstClasses.add(clazz2_processed);
                    System.out.println("Append to-instrument classes "+clazz2_processed+" from usage analysis");
                }
            }
        }
    }

    private Set<String> scanImportedClassesFromDiffFile(String clazz)
    {
        return BashUtil.executeBashCommand("find "+ConfigManager.config.getString(ConfigManager.SYSTEM_DIR_PATH_KEY)
                +" -name \""+clazz.substring(clazz.lastIndexOf('.') + 1)+".java\" -exec cat {} + | sed -n '/import "
                +ConfigManager.config.getString(ConfigManager.SYSTEM_PACKAGE_PREFIX_KEY)+"/p'");
    }

    private void initFromConfigFile()
    {
        for(String str: ConfigManager.config.getStringArray(ConfigManager.INSTRUMENT_STATE_FIELDS_KEY))
        {
            if(str.equals(""))
                continue;

            String[] instItem = str.split("\\^", -1);
            String fieldName = instItem[0];
            String valMethodName = "";
            if (instItem.length > 1) {
                valMethodName = instItem[1];
            }
            stateFields.put(fieldName, valMethodName);
        }
    }

    private void appendFromConfigFile()
    {
        opInstClasses.addAll(Arrays.asList(ConfigManager.config.getStringArray(ConfigManager.INSTRUMENT_CLASS_ALLMETHODS_KEY)));
    }

    private void initFromAllClasses()
    {
        String prefix = ConfigManager.config.getString(ConfigManager.SYSTEM_PACKAGE_PREFIX_KEY);
        Reflections reflections = new Reflections(prefix, new SubTypesScanner(false));
        Set<String> allClasses  = reflections.getAllTypes();
        opInstClasses.addAll(allClasses);
    }

    class OpInstClassesWrapper
    {
        Set<String> opInstClasses = new HashSet<String>() {{}};
        OpInstClassesWrapper(Set<String> opInstClasses)
        {
            this.opInstClasses = opInstClasses;
        }
    }

    private void initFromDumpedFiles()
    {
        File pointFileDir = new File(FileLayoutManager.getPathForPreloadInstrumentInputDir() + "/" + FileLayoutManager.INSTRUMENT_POINTS_FILE_NAME);
        if (!pointFileDir.exists())
        {
            System.err.println("FILE " + pointFileDir.getAbsolutePath() + " not exists!");
            System.exit(-1);
        }

        for (final File pointFile : pointFileDir.listFiles()) {
            if (!pointFile.isDirectory()) {
                try{
                    byte[] encoded = Files.readAllBytes(pointFile.toPath());
                    OpInstClassesWrapper opInstClassesWrapper = GsonUtils.gsonPrettyPrinter.fromJson(new String(encoded, StandardCharsets.US_ASCII), OpInstClassesWrapper.class);
                    opInstClasses.addAll(opInstClassesWrapper.opInstClasses);
                }catch (Exception ex)
                {
                    ex.printStackTrace();
                    System.exit(-1);
                }
            }
        }
    }

    private void dumpInstrumentPoints()
    {
        try {
            File pointFile = new File(FileLayoutManager.getPathForInstrumentPointFile());
            //cleanup old one
            Files.deleteIfExists(pointFile.toPath());

            Writer writer = new BufferedWriter(new OutputStreamWriter(
                    new FileOutputStream(pointFile)));
            writer.write(GsonUtils.gsonPrettyPrinter.toJson(new OpInstClassesWrapper(opInstClasses)));
            writer.close();
        } catch (Exception ex) {
            ex.printStackTrace();
        }
    }

    private void excludeSpecifiedClasses()
    {
        String[] exclude_class_list = ConfigManager.config.getStringArray(ConfigManager.EXCLUDE_CLASS_LIST_KEY);
        for(String clazz:exclude_class_list)
        {
            List<String> result = new ArrayList<>();
            for(String s : opInstClasses)
                if(s.contains(clazz))
                    result.add(s);

            for(String toremove: result)
            {
                if (opInstClasses.remove(toremove))
                    System.out.println("Remove to-instrument classes "+toremove+" due to excluding list");
            }
        }
    }

    private void appendTrackedStates() {
        int total = 0;
        for (String clazz : opInstClasses) {
            try {
                ClassPool pool = ClassPool.getDefault();
                CtClass cc = resolveCtClass(pool, clazz);
                for (CtField field : cc.getDeclaredFields()) {
                    //TODO: fix this
                    //if(Collection.class.isAssignableFrom(field.getClass())) {
                    if (field.getType().getName().equals("java.util.Map") ||
                            field.getType().getName().equals("java.util.HashMap") ||
                            field.getType().getName().equals("java.util.List")) {
                        String fullName = clazz + "." + field.getName();
                        stateFields.putIfAbsent(fullName, ".size()");
                    }

//                    if (field.getType().getName().equals("java.lang.Long") ||
//                            field.getType().getName().equals("java.lang.Byte") ||
//                            field.getType().getName().equals("java.lang.Integer") ||
//                            field.getType().getName().equals("java.lang.Boolean") ||
//                            field.getType().getName().equals("java.lang.Short") ||
//                            field.getType().getName().equals("long") ||
//                            field.getType().getName().equals("byte") ||
//                            field.getType().getName().equals("int") ||
//                            field.getType().getName().equals("boolean") ||
//                            field.getType().getName().equals("short")) {
//                        String fullName = clazz + "." + field.getName();
//                        stateFields.put(fullName, "");
//                    }
                }
                total++;
                cc.defrost();
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
        System.out.println("Instrument "+total+" fields");
        for(String fieldName: stateFields.keySet())
        {
            System.out.println("Instrument field "+fieldName);
        }
    }

    private CtClass resolveCtClass(ClassPool pool, String className) throws NotFoundException {
        try {
            return pool.get(className);
        } catch (NotFoundException e) {
            // Fallback: some classes may be inner classes where Javassist expects $ separators
            // Try progressively replacing the right-most '.' with '$', then continue leftwards
            String temp = className;
            while (true) {
                int idx = temp.lastIndexOf('.');
                if (idx == -1) {
                    break;
                }

                temp = temp.substring(0, idx) + '$' + temp.substring(idx + 1);
                try {
                    return pool.get(temp);
                } catch (NotFoundException ignored) {
                    // continue replacing further left
                }
            }
            throw e;
        }
    }


    public DynamicClassModifier()
    {
        if(ConfigManager.config.getBoolean(ConfigManager.FORCE_INSTRUMENT_NOTHING_KEY))
            return;

        //in two cases we init from all classes 1)gen mode with full mode 2)in verify mode, then we filter
        if(ConfigManager.getGentraceInstrumentMode().equals(ConfigManager.InstrumentMode.FULL) || System.getProperty("ok.invmode").equals("verify")
        ||System.getProperty("ok.invmode").equals("prod"))
        {
            initFromAllClasses();
            excludeSpecifiedClasses();
            appendFromConfigFile();
            appendTrackedStates();
            //dumpInstrumentPoints();
        }
        else if(ConfigManager.getGentraceInstrumentMode().equals(ConfigManager.InstrumentMode.STRICT_SELECTIVE)) {
            initFromConfigFile();
            initFromDiffFileFromCommit(false);
            excludeSpecifiedClasses();
            appendFromConfigFile();
            appendTrackedStates();
            //dumpInstrumentPoints();
        }
        else if(ConfigManager.getGentraceInstrumentMode().equals(ConfigManager.InstrumentMode.RELAXED_SELECTIVE)) {
            initFromConfigFile();
            initFromDiffFileFromCommit(true);
            excludeSpecifiedClasses();
            appendFromConfigFile();
            // Commented out to not include all fields,
            // and only include the ones specified manually instead
            //appendTrackedStates();
            //dumpInstrumentPoints();
        }
        else if(ConfigManager.getGentraceInstrumentMode().equals(ConfigManager.InstrumentMode.SPECIFIED_SELECTIVE)) {
            initFromDumpedFiles();
            excludeSpecifiedClasses();
            appendFromConfigFile();
            appendTrackedStates();
        }
        else {
            System.err.println("Unexpected path, abort");
            System.exit(-1);
        }
    }

    static class StateAccessPoint {
        String className;
        String methodName;
        String fieldName;
        int lineNum;

        public StateAccessPoint(String className, String methodName, String fieldName, int lineNum) {
            this.className = className;
            this.methodName = methodName;
            this.fieldName = fieldName;
            this.lineNum = lineNum;
        }
    }

    //from descriptor to hookpoint, this is modeled after reflection package internal logic
    private static StateAccessPoint parse(String descriptor, String fieldName) {
        int p0 = descriptor.lastIndexOf('(');
        String memberKey = p0 != -1 ? descriptor.substring(0, p0) : descriptor;
        String methodParameters = p0 != -1 ? descriptor.substring(p0 + 1, descriptor.lastIndexOf(')')) : "";

        int p1 = memberKey.lastIndexOf('.');
        String className = memberKey.substring(memberKey.lastIndexOf(' ') + 1, p1);
        String memberName = memberKey.substring(p1 + 1);

        int p2 = descriptor.lastIndexOf('#');
        String lineNumStr = descriptor.substring(p2 + 1);

        return new StateAccessPoint(className, memberName, fieldName, Integer.parseInt(lineNumStr));
    }

    private static String getStateShortName(String longName) {
        int p1 = longName.lastIndexOf('.');
        return longName.substring(p1 + 1);
    }

    private static Field findFieldInHierarchy(Class<?> ownerClass, String fieldName) {
        Class<?> current = ownerClass;
        while (current != null) {
            try {
                Field f = current.getDeclaredField(fieldName);
                f.setAccessible(true);
                return f;
            } catch (NoSuchFieldException ignored) {
                current = current.getSuperclass();
            }
        }
        return null;
    }

    private static Method findZeroArgMethodInHierarchy(Class<?> ownerClass, String methodName) {
        Class<?> current = ownerClass;
        while (current != null) {
            try {
                Method m = current.getDeclaredMethod(methodName);
                m.setAccessible(true);
                return m;
            } catch (NoSuchMethodException ignored) {
                current = current.getSuperclass();
            }
        }
        return null;
    }

    private static Field findFieldInHierarchy(Object ownerObject, String fieldName) {
        Class<?> current = ownerObject.getClass();
        while (current != null) {
            try {
                Field f = current.getDeclaredField(fieldName);
                f.setAccessible(true);
                return f;
            } catch (NoSuchFieldException ignored) {
                current = current.getSuperclass();
            }
        }
        return null;
    }

    private static Object applyAccessorChain(Object value, String valMethodSuffix) throws Throwable {
        if (value == null || valMethodSuffix == null || valMethodSuffix.trim().isEmpty()) {
            return value;
        }

        String expr = valMethodSuffix.trim();
        int cursor = 0;
        Object current = value;
        while (cursor < expr.length()) {
            if (current == null) {
                return null;
            }

            if (expr.charAt(cursor) != '.') {
                break;
            }
            cursor++;

            int start = cursor;
            while (cursor < expr.length()) {
                char ch = expr.charAt(cursor);
                if (Character.isJavaIdentifierPart(ch)) {
                    cursor++;
                } else {
                    break;
                }
            }
            if (start == cursor) {
                break;
            }
            String methodName = expr.substring(start, cursor);

            boolean isMethodCall = cursor + 1 < expr.length() && expr.charAt(cursor) == '(' && expr.charAt(cursor + 1) == ')';
            if (isMethodCall) {
                cursor += 2;

                Method method = findZeroArgMethodInHierarchy(current.getClass(), methodName);
                if (method == null) {
                    return null;
                }
                current = method.invoke(current);
                continue;
            }

            Field field = findFieldInHierarchy(current, methodName);
            if (field == null) {
                return null;
            }
            current = field.get(current);
        }
        return current;
    }

    private static long coerceToLong(Object value) {
        if (value == null) {
            return 0L;
        }
        if (value instanceof Number) {
            return ((Number) value).longValue();
        }
        if (value instanceof Boolean) {
            return ((Boolean) value) ? 1L : 0L;
        }
        if (value instanceof Map) {
            return ((Map<?, ?>) value).size();
        }
        if (value instanceof Collection) {
            return ((Collection<?>) value).size();
        }
        if (value.getClass().isArray()) {
            return java.lang.reflect.Array.getLength(value);
        }
        return 0L;
    }

    public static long readStateValueByReflection(
            Object target,
            String ownerClassName,
            String fieldName,
            String valMethodSuffix) {
        try {
            Class<?> ownerClass = Class.forName(ownerClassName);
            Field f = findFieldInHierarchy(ownerClass, fieldName);
            if (f == null) {
                return 0L;
            }

            Object value = f.get(target);
            Object transformedValue = applyAccessorChain(value, valMethodSuffix);
            return coerceToLong(transformedValue);
        } catch (Throwable ex) {
            return 0L;
        }
    }

    private Map<String, List<StateAccessPoint>> scan() {
        List<StateAccessPoint> stateAccessPoints = new ArrayList<>();

        String prefix = ConfigManager.config.getString(ConfigManager.SYSTEM_PACKAGE_PREFIX_KEY);
        Reflections reflections = new Reflections(prefix,
                new MemberUsageScanner());
        try {
            for (String fieldKey : stateFields.keySet()) {
                System.out.println("Scanning the usage of field " + fieldKey);
                for (String str : reflections.getStore().get(MemberUsageScanner.class.getSimpleName(), fieldKey)) {
                    System.out.println(str);
                    stateAccessPoints.add(parse(str, fieldKey));
                }
            }

        } catch (Exception ex) {
            ex.printStackTrace();
            //exceptions here will be critical
            System.err.println("[ERROR] Abort!");
            System.exit(-1);
        }

        //we need to group in classes so it can be modified one by one
        Map<String, List<StateAccessPoint>> map = stateAccessPoints.stream().collect(Collectors.groupingBy(w -> w.className));
        return map;
    }

    public void modifyOperationEntry(Set<String> allowedSet) {

        ClassPool pool = ClassPool.getDefault();

        int succMethodCounter = 0;
        int failClassCounter = 0;
        System.out.println("opInstClasses.size() "+opInstClasses.size());

        List<String> disabledList = Arrays.asList(ConfigManager.config.getStringArray(ConfigManager.EXCLUDE_METHOD_LIST_KEY));
        System.out.println("disabledList"+disabledList);

        OpTriggerEvent event = new OpTriggerEvent();

        for (String cName : opInstClasses) {
            //skip subclass
            //if (cName.contains("$"))
            //    continue;

            if(ifClassMatchTargetTestClass(cName))
            {
                //we don't want to inject in test class and result a lot of traces we are not interested!
                continue;
            }

            int localCounter = 0;
            try {
                //only get the part before @
                //e.g. org.apache.hadoop.hbase.regionserver.MemStore@heapSizeChange -> org.apache.hadoop.hbase.regionserver.MemStore
                String cNameNoMethod = cName.split("\\@")[0];
                String methodName = cName.split("\\@").length>1?cName.split("\\@")[1]:null;
                CtClass cc = resolveCtClass(pool, cNameNoMethod);
                for (CtMethod m : cc.getDeclaredMethods()) {
                    if (allowedSet != null && !allowedSet.contains(m.getLongName()))
                        continue;

                    if(methodName!=null && !m.getName().equals(methodName))
                        continue;

                    if(disabledList.contains(cNameNoMethod+"@"+methodName))
                    {
                        System.out.println("Skip unwanted method:"+ cNameNoMethod+"@"+methodName);
                        continue;
                    }

                    if (m.isEmpty()) {
                        continue;
                    }

                    m.insertBefore(
                            "{"+EventTracer.class.getName()+".registerOpEvent(\"" + m.getLongName() + "\");}");
                            // "{"+EventTracer.class.getName()+".registerOpEvent(\"" + m.getName() + "\");}");
                    localCounter++;

                    //pre-init for event map
                    event.opName = m.getLongName();
                    if (!EventTracer.instance.eventMap.containsKey(event.getMapKey())) {
                        //fixme: add sync back
                        //eventMap.put(event, Collections.synchronizedList(new ArrayList<>()));
                        //eventMap.put(event, (new ArrayList<>()));
                        //eventMap.put(event, (new TimeToLiveList(time_window_length_in_millis)));
                        EventTracer.instance.eventMap.put(event.getMapKey(), EventListBuilder.buildEventList(event.getClass()));
                    }
                }

                //lazy dump
                //cc.toClass();
                toDumpClasses.put(cc.getName(),cc);
            } catch (Exception ex) {
                ex.printStackTrace();
                failClassCounter++;

                continue;
            }
            succMethodCounter += localCounter;
            System.out.println("prepare for " + cName);
        }

        System.out.println("succMethodCounter" + succMethodCounter + " failClassCounter" + failClassCounter);
    }

    public void modifyStateAccess(Set<String> allowedSet) {
        if(ConfigManager.config.getBoolean(ConfigManager.FORCE_TRACK_NO_STATES_KEY))
            return;

        ClassPool pool = ClassPool.getDefault();

        int succMethodCounter = 0;
        int failClassCounter = 0;
        Map<String, List<StateAccessPoint>> map = scan();

        List<String> disabledList = Arrays.asList(ConfigManager.config.getStringArray(ConfigManager.EXCLUDE_METHOD_LIST_KEY));
        System.out.println("disabledList"+disabledList);

        StateUpdateEvent event = new StateUpdateEvent();

        for (String cName : map.keySet()) {
            int localCounter = 0;
            try {
                if(ifClassMatchTargetTestClass(cName))
                    //we don't want to inject in test class and result a lot of traces we are not interested!
                    continue;

                CtClass cc = resolveCtClass(pool, cName);
                cc.defrost();

                //important, we found that if a method contains several inject points, it's very likely to cause problems like
                // 1) testCreateAfterCloseShouldFail(org.apache.zookeeper.test.SessionInvalidationTest)
                // java.lang.VerifyError: (class: org/apache/zookeeper/common/PathTrie$TrieNode, method: getChild signature: (Ljava/lang/String;)Lorg/apache/zookeeper/common/PathTrie$TrieNode;) Stack size too large
                //         at org.apache.zookeeper.common.PathTrie.<init>(PathTrie.java:189)
                //         at org.apache.zookeeper.server.DataTree.<init>(DataTree.java:112)
                //         at org.apache.zookeeper.server.ZKDatabase.<init>(ZKDatabase.java:84)
                //         at org.apache.zookeeper.server.ZooKeeperServer.<init>(ZooKeeperServer.java:158)
                //         at org.apache.zookeeper.server.ZooKeeperServer.<init>(ZooKeeperServer.java:192)
                //         at org.apache.zookeeper.test.ClientBase.createNewServerInstance(ClientBase.java:343)
                //         at org.apache.zookeeper.test.ClientBase.startServer(ClientBase.java:429)
                //         at org.apache.zookeeper.test.ClientBase.setUp(ClientBase.java:422)
                //         at sun.reflect.NativeMethodAccessorImpl.invoke0(Native Method)
                //         at sun.reflect.NativeMethodAccessorImpl.invoke(NativeMethodAccessorImpl.java:62)

                List<StateAccessPoint> points = map.get(cName);
                Map<String, List<StateAccessPoint>> pByMethodName = new HashMap<>();
                for(StateAccessPoint p: points)
                {
                    pByMethodName.putIfAbsent(p.methodName,new ArrayList<>());
                    pByMethodName.get(p.methodName).add(p);
                }

                for (Map.Entry<String, List<StateAccessPoint>> entry : pByMethodName.entrySet()) {
                    String methodName = entry.getKey();
                    if (methodName.contains("<init>"))
                        continue;
                    if (methodName.contains("$"))
                        continue;

                    String fullName = cName + "@" + methodName;
                    if (disabledList.contains(fullName)) {
                        System.out.println("Skip unwanted method:" + fullName);
                        continue;
                    }

                    List<String> targetStateFields = entry.getValue().stream()
                            .map(p -> p.fieldName)
                            .filter(fieldName -> allowedSet == null || allowedSet.contains(fieldName))
                            .distinct()
                            .collect(Collectors.toList());
                    if (targetStateFields.isEmpty()) {
                        continue;
                    }

                    List<CtMethod> candidateMethods = Arrays.stream(cc.getDeclaredMethods())
                            .filter(m -> m.getName().equals(methodName))
                            .collect(Collectors.toList());
                    if (candidateMethods.isEmpty()) {
                        continue;
                    }

                    for (CtMethod m : candidateMethods) {
                        if (m.isEmpty()) {
                            continue;
                        }

                        final Set<String> targetFieldSet = new HashSet<>(targetStateFields);
                        try {
                            m.instrument(new ExprEditor() {
                                @Override
                                public void edit(FieldAccess f) throws CannotCompileException {
                                    if (!f.isReader() && !f.isWriter()) {
                                        return;
                                    }

                                    String accessedFieldKey = f.getClassName() + "." + f.getFieldName();
                                    if (!targetFieldSet.contains(accessedFieldKey)) {
                                        return;
                                    }

                                    String valMethodSuffix = stateFields.get(accessedFieldKey);
                                    if (valMethodSuffix == null) {
                                        return;
                                    }

                                    String escapedSuffix = valMethodSuffix
                                            .replace("\\", "\\\\")
                                            .replace("\"", "\\\"");

                                    String reflectionValueExpr;
                                    if (f.isStatic()) {
                                        reflectionValueExpr = DynamicClassModifier.class.getName()
                                            + ".readStateValueByReflection(null, \""
                                            + f.getClassName()
                                            + "\", \""
                                            + f.getFieldName()
                                            + "\", \""
                                            + escapedSuffix
                                            + "\")";
                                    } else {
                                        reflectionValueExpr = DynamicClassModifier.class.getName()
                                            + ".readStateValueByReflection($0, \""
                                            + f.getClassName()
                                            + "\", \""
                                            + f.getFieldName()
                                            + "\", \""
                                            + escapedSuffix
                                            + "\")";
                                    }

                                    String eventStmt = EventTracer.class.getName()
                                        + ".registerStateEvent(\""
                                        + accessedFieldKey
                                        + "\",\""
                                        + methodName
                                        + "\", (long)"
                                        + reflectionValueExpr
                                        + ");";

                                    if (f.isReader()) {
                                        f.replace("{ $_ = $proceed($$); " + eventStmt + " }");
                                    } else {
                                        f.replace("{ $proceed($$); " + eventStmt + " }");
                                    }
                                }
                            });

                            System.out.println("instrument now for " + m.getLongName() + " via field-access hooks");

                            for (String fieldName : targetStateFields) {
                                event.stateName = fieldName;
                                event.sourceMethodName = methodName;
                                if (!EventTracer.instance.eventMap.containsKey(event.getMapKey())) {
                                    EventTracer.instance.eventMap.put(event.getMapKey(), EventListBuilder.buildEventList(event.getClass()));
                                }
                            }
                            localCounter++;
                        } catch (Exception ex) {
                            ex.printStackTrace();
                        }
                    }
                }

                //drafts
                //cc.toBytecode().;
                //Bytecode bc = new Bytecode();
                //bc.toCodeAttribute().computeMaxStack();

                //lazy dump
                //cc.toClass();
                toDumpClasses.put(cc.getName(),cc);
            } catch (Exception ex) {
                ex.printStackTrace();
                failClassCounter++;

                continue;
            }
            succMethodCounter += localCounter;
            System.out.println("prepare for " + cName);
        }

        System.out.println("succMethodCounter" + succMethodCounter + " failClassCounter" + failClassCounter);
    }

    public void writeToClasses() {
        int succDumpCounter = 0;
        int failDumpCounter = 0;
        for (CtClass ctClass : toDumpClasses.values()) {
            try {
                ctClass.toClass();
                succDumpCounter++;
                System.out.println("Successfully dump " + ctClass.getName());
            } catch (Exception ex) {
                failDumpCounter++;
                System.out.println("Fail to dump " + ctClass.getName());
                ex.printStackTrace();
            }
        }
        System.out.println("Instrument classes finished");
        System.out.println("succDumpCounter" + succDumpCounter + " failDumpCounter" + failDumpCounter);
    }

    //we want to cut at the end of test methods so our invs wouldn't include some boring events like "shutdown"
    public void markEndOfTestMethods()
    {
        ClassPool pool = ClassPool.getDefault();
        String testName = System.getProperty("ok.testname");
        int errCounters = 0;
        {
            try {
                CtClass cc = resolveCtClass(pool, testName);
                cc.defrost();

                for(CtMethod m: cc.getMethods()){
                    if (!m.hasAnnotation("org.junit.Test")) {
                        continue;
                    }
                    System.out.println("insert marker at "+m.getLongName());

                    try {
                        String stmt = "{"+EventTracer.class.getName()+".registerMarkerEvent("+ MarkerEvent.Marker.EndOfTest.ordinal() +");}";
                        m.insertAfter(stmt);
                    } catch (Exception ex) {
                        //suppress known errors
                        if(!ex.getMessage().contains("no method body"))
                        {
                            ex.printStackTrace();
                        }
                        {
                            errCounters++;
                        }
                    }
                }

                //lazy dump
                //cc.toClass();
                toDumpClasses.put(cc.getName(),cc);
            } catch (Throwable ex) {
                //we somehow encounter Exception in thread "main" java.lang.NoSuchMethodError: javassist.CtMethod.hasAnnotation(Ljava/lang/String;)Z
                ex.printStackTrace();
                if(ex instanceof NoSuchMethodError)
                {
                    System.err.println("If the error is Exception in thread \"main\" java.lang.NoSuchMethodError: javassist.CtMethod.hasAnnotation(Ljava/lang/String;)Z");
                    System.err.println("potential hints: reorder the class loading to bring forward oathkeeper javassist, this might be a conflict between oathkeeper and target system dependency");
                }
            }
            System.out.println("prepare for test " + testName);
        }

        System.out.println("suppress " + errCounters+" no method body errors in markEndOfTestMethods()");

    }

    public void modifyAll() {
        modifyOperationEntry(null);
        modifyStateAccess(null);
        writeToClasses();
    }

    public void modifySelectively(Set<String> opSet, Set<String> stateSet) {
        long startTime = System.currentTimeMillis();

        modifyOperationEntry(opSet);
        modifyStateAccess(stateSet);
        writeToClasses();

        long endTime = System.currentTimeMillis();
        System.out.println("modifySelectively took" + (endTime - startTime) + " milliseconds");
    }
}
