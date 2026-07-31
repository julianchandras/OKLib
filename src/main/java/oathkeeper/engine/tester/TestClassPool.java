package oathkeeper.engine.tester;

import oathkeeper.runtime.ConfigManager;
import org.reflections8.Reflections;
import org.reflections8.scanners.SubTypesScanner;

import java.util.*;

public class TestClassPool {

    //this is just for testing use, be careful not to set true in real use!!
    final static boolean ABORT_AFTER_THREE_TEST = false;
    static int abort_count_down = 3;

    //save pointer to parent
    private List<String> classLst = new ArrayList<>();

    public void registerAllClass() throws Exception
    {
        String prefix = ConfigManager.config.getString(ConfigManager.SYSTEM_PACKAGE_PREFIX_KEY);
        String regex = ConfigManager.config.getString(ConfigManager.TEST_CLASS_NAME_REGEX_KEY);
        String[] specifiedClassList = ConfigManager.config.getStringArray(ConfigManager.SPECIFIED_TEST_CLASS_LIST_KEY);
        if(prefix==null || regex==null)
        {
            throw new RuntimeException("system_package_prefix or test_class_name_regex not set in the config!");
        }

        System.out.println("Start to analyze all test classes with prefix: "+ prefix);
        Reflections reflections = new Reflections(prefix, new SubTypesScanner(false));

        Set<String> allClasses = new HashSet<>();
        String baseClass = ConfigManager.config.getString(ConfigManager.TEST_DISCOVERY_BASE_CLASS_KEY, "");
        String discoveryMode = ConfigManager.config.getString(ConfigManager.TEST_DISCOVERY_MODE_KEY, "subtypes");
        if(!baseClass.isEmpty())
        {
            for(Class<?> clazz : reflections.getSubTypesOf(Class.forName(baseClass)))
                allClasses.add(clazz.getName());
        }
        else if("store".equalsIgnoreCase(discoveryMode))
        {
            for(Set<String> subs : reflections.getStore().get("SubTypesScanner").values())
                allClasses.addAll(subs);
        }
        else
        {
            for(Class clazz : reflections.getSubTypesOf(Object.class))
                allClasses.add(clazz.getName());
        }

        for(String clazzName:allClasses)
        {
            //skip subclass
            if(clazzName.contains("$"))
                continue;

            String simpleName = clazzName.substring(clazzName.lastIndexOf('.')+1);
            if(!simpleName.matches(regex))
                continue;

            if (System.getProperty("ok.verify_test_package") != null &&
                    !System.getProperty("ok.verify_test_package").isEmpty())
            {
                String packageName = null;
                int iend = clazzName.lastIndexOf(".");
                if (iend != -1)
                {
                    packageName= clazzName.substring(0 , iend);
                    if (!packageName.equals(System.getProperty("ok.verify_test_package")))
                        continue;
                }
            }

            if(specifiedClassList.length>0)
                if(!Arrays.asList(specifiedClassList).contains(clazzName))
                    continue;

            System.out.println("registering for test class "+clazzName);
            register(clazzName);

            if(ConfigManager.config.getBoolean(ConfigManager.VERIFY_ABORT_AFTER_THREE_TEST_KEY))
            {
                if(abort_count_down>1)
                    abort_count_down--;
                else
                {
                    System.out.println("WARN: break after three tests!!!!!");
                    break;
                }
            }
        }
        System.out.println("Finished with "+classLst.size()+" test classes added.");
    }

    public void registerSpecificClasses() throws Exception
    {
        String className = System.getProperty("ok.testname");
        register(className);
    }

    public void register(String clazzName)
    {
        classLst.add(clazzName);
    }

    public Class getClass(String classname) throws Exception
    {
        return Class.forName(classname);
    }

    Collection<String> getClasses()
    {
        return classLst;
    }
}